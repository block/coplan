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

      @plan.references.find_or_create_by!(url: url) do |r|
        r.key = params[:reference][:key].presence
        r.title = params[:reference][:title].presence
        r.reference_type = ref_type
        r.source = "explicit"
        r.target_plan_id = target_plan_id
      end

      redirect_to plan_path(@plan), notice: "Reference added."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to plan_path(@plan), alert: e.message
    end

    def destroy
      authorize!(@plan, :update?)

      ref = @plan.references.find(params[:id])
      ref.destroy!
      redirect_to plan_path(@plan), notice: "Reference removed."
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end
  end
end
