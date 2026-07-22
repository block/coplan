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
          format.turbo_stream { render turbo_stream: toast_stream("Choose at least one file to upload.", "alert") }
          format.html { redirect_to plan_path(@plan, anchor: "footnote-attachments"), alert: "Choose at least one file to upload." }
        end
      end

      errors = []
      files.each do |file|
        result = Plans::AddAttachment.call(plan: @plan, file: file, user: current_user)
        errors << "#{file.original_filename}: #{result.error}" unless result.success?
      end

      uploaded = files.size - errors.size
      notice = "#{uploaded} #{"file".pluralize(uploaded)} uploaded." if uploaded.positive?
      alert = errors.join(" ") if errors.any?

      respond_to do |format|
        # In-place: swap the attachments section where it stands and toast —
        # never bounce the reader to the top of the plan they're in.
        format.turbo_stream { render_attachments_update(notice: notice, alert: alert) }
        format.html do
          redirect_to plan_path(@plan, anchor: "footnote-attachments"),
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
          redirect_to plan_path(@plan, anchor: "footnote-attachments"), notice: "Attachment removed."
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
      attachments = @plan.attachments_attachments.includes(:blob).order(created_at: :desc)
      streams = [
        turbo_stream.replace("plan-attachments",
          partial: "coplan/plans/attachments",
          locals: { plan: @plan, attachments: attachments }),
        # The count shows in the footnote header AND the document outline —
        # both were rendered by the redirect this stream response replaced.
        count_stream("attachments-count", attachments.size),
        count_stream("nav-attachments-count", attachments.size)
      ]
      streams << toast_stream(notice, "notice") if notice
      streams << toast_stream(alert, "alert") if alert
      render turbo_stream: streams
    end

    def count_stream(id, count)
      turbo_stream.replace(id,
        html: helpers.content_tag(:span, count, class: "section-count", id: id))
    end

    def toast_stream(message, kind)
      turbo_stream.append("coplan-toasts",
        helpers.content_tag(:div, message,
          class: "flash flash--#{kind} toasts__toast",
          role: "status",
          data: { controller: "coplan--toast" }))
    end
  end
end
