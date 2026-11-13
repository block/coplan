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
      Result = Struct.new(:attachment, :error, :reused, keyword_init: true) do
        def success? = error.nil?
        def reused? = reused == true
      end

      def self.call(**kwargs)
        new(**kwargs).call
      end

      def initialize(plan:, file:, user:, actor_type: nil, actor_id: nil, agent_name: nil, api_token_id: nil)
        @plan = plan
        @file = file
        @user = user
        @actor_type = actor_type
        @actor_id = actor_id
        @agent_name = agent_name
        @api_token_id = api_token_id
      end

      def call
        error = validate_file
        return Result.new(error: error) if error
        return Result.new(error: "Save plan changes before uploading files") if @plan.has_changes_to_save?

        io = @file.open
        candidate = ActiveStorage::Blob.build_after_unfurling(io: io,
          filename: @file.original_filename, content_type: @file.content_type)
        existing = matching_attachment(candidate.checksum, candidate.byte_size)
        return Result.new(attachment: existing, reused: true) if existing

        blob = ActiveStorage::Blob.create_and_upload!(
          io: io,
          filename: @file.original_filename,
          content_type: @file.content_type,
          metadata: uploader_metadata
        )

        # Upload outside the row lock so storage latency does not block edits.
        # Recheck under the lock: another upload may have attached these bytes
        # while this one was in flight. Purge the unused blob after the lock.
        result = @plan.with_lock do
          existing = matching_attachment(blob.checksum, blob.byte_size, lock: true)
          existing ? Result.new(attachment: existing, reused: true) : attach_blob(blob)
        end
        blob.purge if result.attachment&.blob_id != blob.id
        result
      end

      private

      def attach_blob(blob)
        # `attach` on a persisted, unchanged record saves the plan, which runs
        # the model backstop validation. If content-type sniffing (blob
        # identification) reclassified the file into a disallowed type, the
        # save fails — purge the orphaned blob and surface the validation
        # error. Success is judged by the attachment row actually being
        # persisted (not just attach's return value).
        @plan.attachments.attach(blob)
        attachment = @plan.attachments.attachments.find { |a| a.blob_id == blob.id && a.persisted? }

        if attachment.nil?
          error = @plan.errors.full_messages.to_sentence.presence || "Could not attach file"
          @plan.errors.clear
          @plan.attachment_changes.delete("attachments")
          return Result.new(error: error)
        end

        LogEvent.call(
          plan: @plan,
          actor: @user,
          event_type: "attachment_added",
          after: blob.filename.to_s,
          metadata: { content_type: blob.content_type, byte_size: blob.byte_size },
          actor_type: @actor_type,
          actor_id: @actor_id,
          agent_name: @agent_name,
          api_token_id: @api_token_id
        )

        Result.new(attachment: attachment)
      end

      def matching_attachment(checksum, byte_size, lock: false)
        scope = @plan.attachments_attachments.joins(:blob).includes(:blob)
          .where(active_storage_blobs: { checksum: checksum, byte_size: byte_size, content_type: Plan::ATTACHMENT_CONTENT_TYPES })
          .order(:created_at, :id)
        scope = scope.lock if lock
        # Some hosts use case-insensitive collations. Base64 checksums must
        # still match exactly, regardless of the database's text comparison.
        scope.detect { |attachment| attachment.blob.checksum == checksum }
      end

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
