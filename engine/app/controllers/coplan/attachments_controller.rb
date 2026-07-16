module CoPlan
  class AttachmentsController < ApplicationController
    before_action :set_plan

    def create
      authorize!(@plan, :update?)

      files = Array(params[:files]).reject(&:blank?)
      if files.empty?
        return redirect_to plan_path(@plan, tab: "attachments"), alert: "Choose at least one file to upload."
      end

      errors = []
      files.each do |file|
        result = Plans::AddAttachment.call(plan: @plan, file: file, user: current_user)
        errors << "#{file.original_filename}: #{result.error}" unless result.success?
      end

      uploaded = files.size - errors.size
      flash_options = {}
      flash_options[:notice] = "#{uploaded} #{"file".pluralize(uploaded)} uploaded." if uploaded.positive?
      flash_options[:alert] = errors.join(" ") if errors.any?
      redirect_to plan_path(@plan, tab: "attachments"), flash_options
    end

    def destroy
      authorize!(@plan, :update?)

      attachment = @plan.attachments_attachments.find(params[:id])
      filename = attachment.blob&.filename.to_s
      content_type = attachment.blob&.content_type
      attachment.purge

      Plans::LogEvent.call(
        plan: @plan,
        actor: current_user,
        event_type: "attachment_removed",
        before: filename,
        metadata: { content_type: content_type }
      )

      redirect_to plan_path(@plan, tab: "attachments"), notice: "Attachment removed."
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end
  end
end
