module CoPlan
  module Api
    module V1
      class PlansController < BaseController
        before_action :set_plan, only: [:show, :update, :versions, :comments]
        before_action :authorize_plan_access!, only: [:show, :update, :versions, :comments]

        def index
          plans = Plan
            .includes(:plan_type, :created_by_user)
            .where.not(status: "brainstorm")
            .or(Plan.where(created_by_user: current_user))
            .order(updated_at: :desc)
          plans = plans.where(status: params[:status]) if params[:status].present?
          render json: plans.map { |p| plan_json(p) }
        end

        def show
          render json: plan_json(@plan).merge(
            current_content: @plan.current_content,
            current_revision: @plan.current_revision
          )
        end

        def create
          plan = Plans::Create.call(
            title: params[:title],
            content: params[:content] || "",
            user: current_user,
            plan_type_id: params[:plan_type_id].presence
          )
          render json: plan_json(plan).merge(
            current_content: plan.current_content,
            current_revision: plan.current_revision
          ), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_content
        rescue ActiveRecord::InvalidForeignKey
          render json: { error: "Invalid plan_type_id" }, status: :unprocessable_content
        end

        def update
          policy = PlanPolicy.new(current_user, @plan)
          unless policy.update?
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          permitted = {}
          permitted[:title] = params[:title] if params.key?(:title)
          permitted[:status] = params[:status] if params.key?(:status)
          permitted[:tags] = params[:tags] if params.key?(:tags)

          @plan.update!(permitted)

          if @plan.saved_changes?
            Broadcaster.replace_to(@plan, target: "plan-header", partial: "coplan/plans/header", locals: { plan: @plan })
          end

          if permitted.key?(:status) && @plan.saved_change_to_status?
            Plans::TriggerAutomatedReviews.call(plan: @plan, new_status: permitted[:status], triggered_by: current_user)
          end

          render json: plan_json(@plan).merge(
            current_content: @plan.current_content,
            current_revision: @plan.current_revision
          )
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_content
        end

        def versions
          versions = @plan.plan_versions.order(revision: :desc)
          render json: versions.map { |v| version_json(v) }
        end

        def comments
          threads = @plan.comment_threads.includes(:comments, :created_by_user).order(created_at: :desc)
          render json: threads.map { |t| thread_json(t) }
        end

        private

        def plan_json(plan)
          {
            id: plan.id,
            title: plan.title,
            status: plan.status,
            current_revision: plan.current_revision,
            tags: plan.tags,
            plan_type_id: plan.plan_type_id,
            plan_type_name: plan.plan_type&.name,
            created_by: plan.created_by_user.name,
            created_at: plan.created_at,
            updated_at: plan.updated_at
          }
        end

        def version_json(version)
          {
            id: version.id,
            revision: version.revision,
            content_sha256: version.content_sha256,
            actor_type: version.actor_type,
            change_summary: version.change_summary,
            created_at: version.created_at
          }
        end

        def thread_json(thread)
          {
            id: thread.id,
            status: thread.status,
            anchor_text: thread.anchor_text,
            anchor_context: thread.anchor_context_with_highlight,
            anchor_valid: thread.anchor_valid?,
            start_line: thread.start_line,
            end_line: thread.end_line,
            out_of_date: thread.out_of_date,
            created_by: thread.created_by_user.name,
            created_at: thread.created_at,
            comments: thread.comments.order(created_at: :asc).map { |c|
              {
                id: c.id,
                author_type: c.author_type,
                agent_name: c.agent_name,
                body_markdown: c.body_markdown,
                created_at: c.created_at
              }
            }
          }
        end
      end
    end
  end
end
