module CoPlan
  class AttachmentsController < ApplicationController
    before_action :set_plan

    def create
      # Anyone signed in can contribute files (like a comment); removal
      # stays with the author.
      authorize!(@plan, :contribute?)

      files = Array(params[:files]).reject(&:blank?)
      if files.empty?
        return respond_to do |format|
          format.json { render json: { attachments: [], errors: [ "Choose at least one file to upload." ] }, status: :unprocessable_content }
          format.turbo_stream { render turbo_stream: toast_stream("Choose at least one file to upload.", "alert") }
          format.html { redirect_to helpers.plan_browse_path(@plan, anchor: "footnote-attachments"), alert: "Choose at least one file to upload." }
        end
      end

      errors = []
      attachments = []
      files.each do |file|
        result = Plans::AddAttachment.call(plan: @plan, file: file, user: current_user)
        if result.success?
          blob = result.attachment.blob
          url = main_app.rails_blob_path(blob, only_path: true)
          attachments << { id: result.attachment.id, filename: blob.filename.to_s,
            content_type: blob.content_type, url: url, reused: result.reused?,
            download_url: main_app.rails_blob_path(blob, disposition: :attachment, only_path: true) }
        else
          errors << "#{file.original_filename}: #{result.error}"
        end
      end

      uploaded = attachments.count { |attachment| !attachment[:reused] }
      reused = attachments.size - uploaded
      notice = []
      notice << "#{uploaded} #{"file".pluralize(uploaded)} uploaded." if uploaded.positive?
      notice << "#{reused} existing #{"file".pluralize(reused)} reused." if reused.positive?
      notice = notice.join(" ").presence
      alert = errors.join(" ") if errors.any?

      respond_to do |format|
        format.json do
          render json: { attachments: attachments, errors: errors, streams: attachment_update_streams.map(&:to_s).join },
            status: attachments.any? ? :created : :unprocessable_content
        end
        # In-place: swap the attachments section where it stands and toast —
        # never bounce the reader to the top of the plan they're in.
        format.turbo_stream { render_attachments_update(notice: notice, alert: alert) }
        format.html do
          redirect_to helpers.plan_browse_path(@plan, anchor: "footnote-attachments"),
            { notice: notice, alert: alert }.compact
        end
      end
    end

    def destroy
      authorize!(@plan, :update?)

      attachment = @plan.attachments_attachments.find(params[:id])
      filename = attachment.blob&.filename.to_s
      content_type = attachment.blob&.content_type
      # purge_later: deletes the attachment row now, pushes the storage-service
      # file deletion to a background job so the request doesn't block on I/O.
      attachment.purge_later

      Plans::LogEvent.call(
        plan: @plan,
        actor: current_user,
        event_type: "attachment_removed",
        before: filename,
        metadata: { content_type: content_type }
      )

      respond_to do |format|
        format.turbo_stream { render_attachments_update(notice: "Attachment removed.") }
        format.html do
          redirect_to helpers.plan_browse_path(@plan, anchor: "footnote-attachments"), notice: "Attachment removed."
        end
      end
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    # Re-renders #plan-attachments in place plus a bottom-corner toast per
    # message — the whole point is that the reader's scroll position never
    # moves.
    def render_attachments_update(notice: nil, alert: nil)
      streams = attachment_update_streams
      streams << toast_stream(notice, "notice") if notice
      streams << toast_stream(alert, "alert") if alert
      render turbo_stream: streams
    end

    def attachment_update_streams
      attachments = @plan.attachments_attachments.includes(:blob).order(created_at: :desc)
      [
        turbo_stream.replace("plan-attachments",
          partial: "coplan/plans/attachments",
          locals: { plan: @plan, attachments: attachments }),
        # The count shows in the footnote header AND the document outline —
        # both were rendered by the redirect this stream response replaced.
        count_stream("attachments-count", attachments.size),
        count_stream("nav-attachments-count", attachments.size)
      ]
    end

    def count_stream(id, count)
      turbo_stream.replace(id,
        html: helpers.plan_section_count(count, id: id))
    end
  end
end
