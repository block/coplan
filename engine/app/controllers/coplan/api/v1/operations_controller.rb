module CoPlan
  module Api
    module V1
      class OperationsController < BaseController
        before_action :set_plan
        before_action :authorize_plan_access!
        # A stale agent write gets rebased through intervening versions
        # below. A stale write over a *human's* hand edit does not — it is
        # refused here, before any of that machinery runs.
        before_action :guard_human_edits!

        def create
          operations = params[:operations]
          base_revision = params[:base_revision]&.to_i

          unless base_revision.present?
            render json: { error: "base_revision is required" }, status: :unprocessable_content
            return
          end

          unless operations.is_a?(Array) && operations.any?
            render json: { error: "operations must be a non-empty array" }, status: :unprocessable_content
            return
          end

          if params[:session_id].present?
            apply_with_session(operations, base_revision)
          elsif params[:lease_token].present?
            apply_with_lease(operations, base_revision)
          else
            apply_direct(operations, base_revision)
          end
        rescue Plans::OperationError => e
          render json: { error: e.message }, status: :unprocessable_content
        rescue Plans::HumanEditGuard::Blocked => e
          render json: e.payload, status: :conflict
        end

        private

        def apply_with_session(operations, base_revision)
          session = @plan.edit_sessions.find_by(id: params[:session_id], actor_id: api_actor_id)
          unless session&.active?
            render json: { error: "Edit session not found, expired, or not open" }, status: :not_found
            return
          end

          applied_count = nil
          ActiveRecord::Base.transaction do
            session.lock!

            unless session.active?
              render json: { error: "Edit session is no longer active" }, status: :conflict
              return
            end

            # Use draft_content if we've already applied ops, otherwise use the
            # session's base revision snapshot so resolved ranges stay consistent
            # with base_revision (not the potentially-advanced current content).
            working_content = session.draft_content
            unless working_content
              base_version = @plan.plan_versions.find_by(revision: session.base_revision)
              working_content = base_version&.content_markdown || @plan.current_content || ""
            end
            result = Plans::ApplyOperations.call(content: working_content, operations: operations)

            session.update!(
              operations_json: session.operations_json + result[:applied],
              draft_content: result[:content]
            )
            applied_count = result[:applied].length
          end

          return if performed?

          render json: {
            session_id: session.id,
            applied: applied_count,
            operations_pending: session.reload.operations_json.length
          }, status: :created
        end

        def apply_with_lease(operations, base_revision)
          lease_token = params[:lease_token]

          lease = @plan.edit_lease
          unless lease&.held_by?(lease_token: lease_token)
            render json: { error: "You do not hold a valid edit lease for this plan" }, status: :conflict
            return
          end

          if @plan.current_revision != base_revision
            render json: {
              error: "Stale revision. Expected #{@plan.current_revision}, got #{base_revision}",
              current_revision: @plan.current_revision
            }, status: :conflict
            return
          end

          create_version_from_operations(operations, base_revision: base_revision)
        rescue EditLease::Conflict => e
          render json: { error: e.message }, status: :conflict
        end

        def apply_direct(operations, base_revision)
          ActiveRecord::Base.transaction do
            @plan.lock!
            @plan.reload
            enforce_human_edit_fence!(base_revision)

            current_content = @plan.current_content || ""

            final_ops = if @plan.current_revision != base_revision
              rebase_and_resolve(operations, base_revision, current_content)
            else
              operations
            end

            return if performed? # rebase_and_resolve may have rendered a conflict

            result = Plans::ApplyOperations.call(content: current_content, operations: final_ops)
            commit_version(current_content, result)
          end
        end

        # Rebase stale operations through the intervening versions
        # (Plans::Rebase). This method keeps the staleness limit, the base
        # lookup and the HTTP mapping of a conflict.
        def rebase_and_resolve(operations, base_revision, current_content)
          stale_gap = @plan.current_revision - base_revision
          if stale_gap > 20
            render json: {
              error: "Too stale — #{stale_gap} revisions behind (max 20). Re-read the plan.",
              current_revision: @plan.current_revision
            }, status: :conflict
            return
          end

          base_version = @plan.plan_versions.find_by(revision: base_revision)
          unless base_version
            render json: { error: "Base revision #{base_revision} not found" }, status: :conflict
            return
          end

          intervening_versions = @plan.plan_versions
            .where("revision > ? AND revision <= ?", base_revision, @plan.current_revision)
            .order(revision: :asc)
            .to_a

          # Stale operations are always resolved against their base; a
          # caller's own _pre_resolved_ranges are not used.
          operations = operations.map do |op|
            op = op.respond_to?(:to_unsafe_h) ? op.to_unsafe_h : op
            op.transform_keys(&:to_s).except("_pre_resolved_ranges")
          end

          Plans::Rebase.call(
            base_content: base_version.content_markdown,
            operations: operations,
            intervening_versions: intervening_versions,
            current_content: current_content
          )
        rescue Plans::Rebase::Conflict => e
          render json: {
            error: "Conflict: #{e.message}",
            current_revision: @plan.current_revision,
            expected: e.expected,
            found: e.found
          }.compact, status: :conflict
          nil
        end

        def create_version_from_operations(operations, base_revision:)
          ActiveRecord::Base.transaction do
            @plan.lock!
            @plan.reload
            enforce_human_edit_fence!(base_revision)

            if @plan.current_revision != base_revision
              render json: {
                error: "Stale revision. Expected #{@plan.current_revision}, got #{base_revision}",
                current_revision: @plan.current_revision
              }, status: :conflict
              return
            end

            current_content = @plan.current_content || ""
            result = Plans::ApplyOperations.call(content: current_content, operations: operations)
            commit_version(current_content, result)
          end
        end

        def commit_version(current_content, result)
          new_revision = @plan.current_revision + 1
          diff = Diffy::Diff.new(current_content, result[:content]).to_s

          version = PlanVersion.create_for_commit!(
            plan: @plan,
            edit_lease_token: params[:lease_token],
            revision: new_revision,
            content_markdown: result[:content],
            actor_type: api_author_type,
            actor_id: api_user_id,
            agent_name: api_agent_name,
            api_token_id: api_token_id,
            change_summary: params[:change_summary],
            diff_unified: diff.presence,
            operations_json: result[:applied],
            base_revision: params[:base_revision]&.to_i,
            reason: params[:reason]
          )

          Plans::AdvanceVersion.call(plan: @plan, version: version)

          @plan.comment_threads.mark_out_of_date_for_new_version!(version)

          # The caller has seen this content — it just wrote it.
          record_plan_read!(@plan, revision: new_revision)

          broadcast_plan_update

          render json: {
            revision: new_revision,
            content_sha256: version.content_sha256,
            applied: result[:applied].length,
            version_id: version.id
          }, status: :created
        end

        # The before_action gives the caller a fast refusal; this is the one
        # that actually holds the line, because it runs under the plan lock
        # that the version creation below shares.
        def enforce_human_edit_fence!(base_revision)
          return if api_author_type == "human"

          Plans::HumanEditGuard.enforce!(
            plan: @plan,
            reader_type: api_reader_type,
            reader_id: api_reader_id,
            base_revision: base_revision
          )
        end

        def broadcast_plan_update
          Broadcaster.replace_to(
            @plan,
            target: "plan-header",
            partial: "coplan/plans/header",
            locals: { plan: @plan }
          )
          Broadcaster.replace_plan_content(@plan)
        end
      end
    end
  end
end
