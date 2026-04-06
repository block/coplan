module CoPlan
  class PlansController < ApplicationController
    before_action :set_plan, only: [:show, :edit, :update, :update_status]

    def index
      @plans = Plan.includes(:plan_type).order(updated_at: :desc)
      @plans = @plans.where(status: params[:status]) if params[:status].present?
      @plans = @plans.where(created_by_user: current_user) if params[:scope] == "mine"
      @plans = @plans.where(plan_type_id: params[:plan_type]) if params[:plan_type].present?

      @plan_types = PlanType.order(:name)

      @plan_unread_counts = current_user.notifications.unread
        .where(plan_id: @plans.select(:id))
        .group(:plan_id)
        .count

      @show_onboarding_banner = CoPlan.configuration.onboarding_banner.present? &&
        !current_user.created_plans.exists?
    end

    def show
      authorize!(@plan, :show?)
      @threads = @plan.comment_threads.includes(:comments, :created_by_user).order(:created_at)
      PlanViewer.track(plan: @plan, user: current_user)
    end

    def edit
      authorize!(@plan, :update?)
    end

    def update
      authorize!(@plan, :update?)
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
      @plan = Plan.find(params[:id])
    end

    def broadcast_plan_update(plan)
      Broadcaster.replace_to(plan, target: "plan-header", partial: "coplan/plans/header", locals: { plan: plan })
    end
  end
end
