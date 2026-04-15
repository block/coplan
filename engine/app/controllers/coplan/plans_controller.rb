module CoPlan
  class PlansController < ApplicationController
    before_action :set_plan, only: [:show, :edit, :update, :update_status, :toggle_checkbox]

    def index
      @plans = Plan.includes(:plan_type, :tags)
        .where.not(status: "brainstorm")
        .or(Plan.where(created_by_user: current_user))
        .order(updated_at: :desc)
      @plans = @plans.where(status: params[:status]) if params[:status].present?
      @plans = @plans.where(created_by_user: current_user) if params[:scope] == "mine"
      @plans = @plans.where(plan_type_id: params[:plan_type]) if params[:plan_type].present?
      @plans = @plans.with_tag(params[:tag]) if params[:tag].present?

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
      @references = @plan.references.order(reference_type: :asc, created_at: :desc)
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

    def toggle_checkbox
      authorize!(@plan, :show?)

      old_text = params[:old_text]
      new_text = params[:new_text]
      base_revision = params[:base_revision]&.to_i

      unless old_text.present? && new_text.present? && base_revision.present?
        render json: { error: "old_text, new_text, and base_revision are required" }, status: :unprocessable_content
        return
      end

      checkbox_pattern = /\A\s*[*+-]\s+\[[ xX]\]\s/
      unless old_text.match?(checkbox_pattern) && new_text.match?(checkbox_pattern)
        render json: { error: "old_text and new_text must be task list items" }, status: :unprocessable_content
        return
      end

      ActiveRecord::Base.transaction do
        @plan.lock!
        @plan.reload

        if @plan.current_revision != base_revision
          render json: { error: "Conflict", current_revision: @plan.current_revision }, status: :conflict
          return
        end

        current_content = @plan.current_content || ""
        result = Plans::ApplyOperations.call(
          content: current_content,
          operations: [{ "op" => "replace_exact", "old_text" => old_text, "new_text" => new_text }]
        )

        new_revision = @plan.current_revision + 1
        diff = Diffy::Diff.new(current_content, result[:content]).to_s

        version = PlanVersion.create!(
          plan: @plan,
          revision: new_revision,
          content_markdown: result[:content],
          actor_type: "human",
          actor_id: current_user.id,
          change_summary: "Toggle checkbox",
          diff_unified: diff.presence,
          operations_json: result[:applied],
          base_revision: base_revision
        )

        @plan.update!(current_plan_version: version, current_revision: new_revision)
        @plan.comment_threads.mark_out_of_date_for_new_version!(version)
      end

      broadcast_plan_update(@plan)
      render json: { revision: @plan.current_revision }
    rescue Plans::OperationError => e
      render json: { error: e.message }, status: :unprocessable_content
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
