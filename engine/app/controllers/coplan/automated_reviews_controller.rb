module CoPlan
  class AutomatedReviewsController < ApplicationController
    before_action :set_plan
    before_action :set_reviewer, only: [:create]

    def create
      authorize!(@plan, :update?)

      AutomatedReviewJob.perform_later(
        plan_id: @plan.id,
        reviewer_id: @reviewer.id,
        plan_version_id: @plan.current_plan_version_id,
        triggered_by: current_user
      )

      redirect_to plan_path(@plan), notice: "#{@reviewer.name} review queued."
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    def set_reviewer
      @reviewer = AutomatedPlanReviewer.enabled.find(params[:reviewer_id])
    end
  end
end
