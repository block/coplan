module CoPlan
  module Api
    module V1
      class AttachmentsController < BaseController
        # For attachment_markdown_snippet — keeps the embed-snippet format in
        # one place so the API and the web UI can't drift apart.
        include CoPlan::AttachmentsHelper

        before_action :set_plan, only: [ :index, :create, :destroy ]
        before_action :authorize_plan_access!, only: [ :index, :create, :destroy ]
        before_action :authorize_plan_write!, only: [ :create, :destroy ]

        def index
          attachments = @plan.attachments_attachments.includes(:blob).order(created_at: :desc)
          render json: attachments.map { |a| attachment_json(a) }
        end

        # Multipart upload: POST with a `file` form field, e.g.
        #   curl -F "file=@./diagram.png" .../plans/:plan_id/attachments
        def create
          file = params[:file]
          unless file.respond_to?(:original_filename)
            return render json: { error: "file is required (multipart form field \"file\")" }, status: :unprocessable_content
          end

          result = Plans::AddAttachment.call(
            plan: @plan,
            file: file,
            user: current_user,
            actor_type: api_author_type,
            actor_id: api_actor_id
          )

          if result.success?
            render json: attachment_json(result.attachment), status: :created
          else
            render json: { error: result.error }, status: :unprocessable_content
          end
        end

        def destroy
          attachment = @plan.attachments_attachments.find_by(id: params[:id])
          unless attachment
            render json: { error: "Attachment not found" }, status: :not_found
            return
          end

          filename = attachment.blob&.filename.to_s
          content_type = attachment.blob&.content_type
          # purge_later: deletes the attachment row now, pushes the
          # storage-service file deletion to a background job.
          attachment.purge_later

          Plans::LogEvent.call(
            plan: @plan,
            actor: current_user,
            event_type: "attachment_removed",
            before: filename,
            metadata: { content_type: content_type },
            actor_type: api_author_type,
            actor_id: api_actor_id
          )

          head :no_content
        end

        private

        def attachment_json(attachment)
          blob = attachment.blob
          url = main_app.rails_blob_path(blob, only_path: true)
          {
            id: attachment.id,
            filename: blob.filename.to_s,
            content_type: blob.content_type,
            byte_size: blob.byte_size,
            uploaded_by: blob.metadata["uploaded_by_name"],
            uploaded_by_id: blob.metadata["uploaded_by_id"],
            created_at: attachment.created_at,
            url: url,
            download_url: main_app.rails_blob_url(blob, disposition: "attachment"),
            markdown: attachment_markdown_snippet(blob, url)
          }
        end
      end
    end
  end
end
