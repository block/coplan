module CoPlan
  module Plans
    # Attaches an uploaded file to a plan, enforcing the size/content-type
    # limits declared on Plan, stamping the uploader into the blob metadata,
    # and logging an `attachment_added` event.
    #
    # Shared by the web AttachmentsController and the API v1
    # AttachmentsController so both surfaces enforce identical rules.
    #
    # Returns a Result with either `attachment` (an ActiveStorage::Attachment)
    # or a human-readable `error` string. Size/type are checked *before* the
    # blob is created so rejected uploads never write to the storage service;
    # the Plan model validation acts as a backstop for any other attach path.
    class AddAttachment
      Result = Struct.new(:attachment, :error, keyword_init: true) do
        def success? = error.nil?
      end

      def self.call(**kwargs)
        new(**kwargs).call
      end

      def initialize(plan:, file:, user:, actor_type: nil, actor_id: nil)
        @plan = plan
        @file = file
        @user = user
        @actor_type = actor_type
        @actor_id = actor_id
      end

      def call
        error = validate_file
        return Result.new(error: error) if error

        blob = ActiveStorage::Blob.create_and_upload!(
          io: @file.open,
          filename: @file.original_filename,
          content_type: @file.content_type,
          metadata: uploader_metadata
        )

        # `attach` on a persisted record saves the plan, which runs the model
        # backstop validation. If content-type sniffing (blob identification)
        # reclassified the file into a disallowed type, the save fails — purge
        # the orphaned blob and surface the validation error.
        if @plan.attachments.attach(blob).nil?
          error = @plan.errors.full_messages.to_sentence.presence || "Could not attach file"
          @plan.errors.clear
          @plan.attachment_changes.delete("attachments")
          blob.purge
          return Result.new(error: error)
        end

        attachment = @plan.attachments.attachments.find { |a| a.blob_id == blob.id }

        LogEvent.call(
          plan: @plan,
          actor: @user,
          event_type: "attachment_added",
          after: blob.filename.to_s,
          metadata: { content_type: blob.content_type, byte_size: blob.byte_size },
          actor_type: @actor_type,
          actor_id: @actor_id
        )

        Result.new(attachment: attachment)
      end

      private

      def validate_file
        return "file is required" if @file.blank? || !@file.respond_to?(:original_filename)

        content_type = @file.content_type.to_s
        unless Plan::ATTACHMENT_CONTENT_TYPES.include?(content_type)
          return "Content type #{content_type.presence || "unknown"} is not allowed. " \
                 "Allowed types: #{Plan::ATTACHMENT_CONTENT_TYPES.join(", ")}"
        end

        if @file.size.to_i > Plan::ATTACHMENT_MAX_BYTES
          return "File is too large (#{@file.size} bytes). Maximum is #{Plan::ATTACHMENT_MAX_BYTES / 1.megabyte} MB"
        end

        nil
      end

      def uploader_metadata
        return {} unless @user
        { "uploaded_by_id" => @user.id, "uploaded_by_name" => @user.name }
      end
    end
  end
end
