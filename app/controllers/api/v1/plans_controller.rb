module Api
  module V1
    class PlansController < BaseController
      before_action :set_plan, only: [:show, :versions, :comments]
      before_action :authorize_plan_access!, only: [:show, :versions, :comments]

      def index
        plans = current_organization.plans
          .where.not(status: "brainstorm")
          .or(current_organization.plans.where(created_by_user: current_user))
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
          user: current_user
        )
        render json: plan_json(plan).merge(
          current_content: plan.current_content,
          current_revision: plan.current_revision
        ), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
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
