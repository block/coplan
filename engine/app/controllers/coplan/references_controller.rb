module CoPlan
  class ReferencesController < ApplicationController
    before_action :set_plan

    def create
      authorize!(@plan, :update?)

      url = params[:reference][:url]
      ref_type = Reference.classify_url(url)
      target_plan_id = nil
      if ref_type == "plan"
        candidate_id = Reference.extract_target_plan_id(url)
        target_plan_id = candidate_id if candidate_id && candidate_id != @plan.id && Plan.exists?(candidate_id)
      end

      ref = @plan.references.find_or_initialize_by(url: url)
      ref.assign_attributes(
        key: params[:reference][:key].presence || ref.key,
        title: params[:reference][:title].presence || ref.title,
        reference_type: ref_type,
        source: "explicit",
        target_plan_id: target_plan_id
      )
      ref.save!

      respond_to do |format|
        format.turbo_stream { render_references_stream }
        format.html { redirect_to plan_path(@plan, tab: "references"), notice: "Reference added." }
      end
    rescue ActiveRecord::RecordInvalid => e
      respond_to do |format|
        format.turbo_stream { render_references_stream }
        format.html { redirect_to plan_path(@plan, tab: "references"), alert: e.message }
      end
    end

    def destroy
      authorize!(@plan, :update?)

      ref = @plan.references.find(params[:id])
      ref.destroy!

      respond_to do |format|
        format.turbo_stream { render_references_stream }
        format.html { redirect_to plan_path(@plan, tab: "references"), notice: "Reference removed." }
      end
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    def render_references_stream
      references = @plan.references.reload.order(reference_type: :asc, created_at: :desc)
      render turbo_stream: turbo_stream.replace(
        "plan-references",
        partial: "coplan/plans/references",
        locals: { references: references, plan: @plan }
      )
    end
  end
end
