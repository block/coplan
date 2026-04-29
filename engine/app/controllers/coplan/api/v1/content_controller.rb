module CoPlan
  module Api
    module V1
      # PUT /api/v1/plans/:plan_id/content — replace plan content wholesale.
      #
      # The agent-friendly edit path: read the plan, edit the markdown
      # locally, then PUT the updated content back. The server diffs
      # against the current revision, decomposes into operations (so
      # comment anchors in unchanged regions survive via OT), and creates
      # a new immutable PlanVersion.
      #
      # Optimistic concurrency: caller MUST supply base_revision matching
      # the plan's current_revision, or the request fails with 409.
      class ContentController < BaseController
        before_action :set_plan
        before_action :authorize_plan_access!

        def update
          if params[:content].nil?
            return render json: { error: "content is required" }, status: :unprocessable_content
          end

          base_revision = params[:base_revision]&.to_i
          unless base_revision.present?
            return render json: { error: "base_revision is required" }, status: :unprocessable_content
          end

          result = Plans::ReplaceContent.call(
            plan: @plan,
            new_content: params[:content].to_s,
            base_revision: base_revision,
            actor_type: api_author_type,
            actor_id: api_actor_id,
            change_summary: params[:change_summary],
            reason: params[:reason]
          )

          if result[:no_op]
            render json: {
              revision: @plan.current_revision,
              applied: 0,
              no_op: true
            }, status: :ok
            return
          end

          version = result[:version]
          render json: {
            revision: version.revision,
            content_sha256: version.content_sha256,
            applied: result[:applied],
            version_id: version.id
          }, status: :created
        rescue Plans::ReplaceContent::StaleRevisionError => e
          render json: {
            error: e.message,
            current_revision: e.current_revision
          }, status: :conflict
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_content
        end
      end
    end
  end
end
