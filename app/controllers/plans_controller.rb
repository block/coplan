class PlansController < ApplicationController
  before_action :scope_to_organization
  before_action :set_plan, only: [:show, :edit, :update, :update_status]

  def index
    @plans = @organization.plans.order(updated_at: :desc)
    @plans = @plans.where(status: params[:status]) if params[:status].present?
  end

  def show
    authorize!(@plan, :show?)
    threads = @plan.comment_threads.includes(:comments, :created_by_user, :plan_version).order(created_at: :asc)
    @active_threads = threads.active
    @archived_threads = threads.archived
  end

  def edit
    authorize!(@plan, :update?)
  end

  def update
    authorize!(@plan, :update?)

    # Content editing is done via the API operations endpoint (which stores
    # positional metadata required by the OT engine). This action only
    # updates metadata fields.
    @plan.update!(title: params[:plan][:title])

    broadcast_plan_update(@plan)
    redirect_to plan_path(@plan), notice: "Plan updated."
  end

  def update_status
    authorize!(@plan, :update_status?)
    new_status = params[:status]
    if Plan::STATUSES.include?(new_status) && @plan.update(status: new_status)
      broadcast_plan_update(@plan)
      if @plan.saved_change_to_status?
        Plans::TriggerAutomatedReviews.call(plan: @plan, new_status: new_status, triggered_by: current_user)
      end
      redirect_to plan_path(@plan), notice: "Status updated to #{new_status}."
    else
      redirect_to plan_path(@plan), alert: "Invalid status."
    end
  end

  private

  def set_plan
    @plan = @organization.plans.find(params[:id])
  end

  def broadcast_plan_update(plan)
    Turbo::StreamsChannel.broadcast_replace_to(
      plan,
      target: "plan-header",
      partial: "plans/header",
      locals: { plan: plan }
    )
  end
end
