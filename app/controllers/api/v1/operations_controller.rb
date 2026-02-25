module Api
  module V1
    class OperationsController < BaseController
      before_action :set_plan
      before_action :authorize_plan_access!

      def create
        operations = params[:operations]
        base_revision = params[:base_revision]&.to_i

        unless base_revision.present?
          render json: { error: "base_revision is required" }, status: :unprocessable_entity
          return
        end

        unless operations.is_a?(Array) && operations.any?
          render json: { error: "operations must be a non-empty array" }, status: :unprocessable_entity
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
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def apply_with_session(operations, base_revision)
        session = @plan.edit_sessions.find_by(id: params[:session_id], actor_id: @api_token.id)
        unless session&.open?
          render json: { error: "Edit session not found or not open" }, status: :not_found
          return
        end

        applied_count = nil
        ActiveRecord::Base.transaction do
          session.lock!

          unless session.open?
            render json: { error: "Edit session is no longer open" }, status: :conflict
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

      # Rebase stale operations: resolve each against a running base snapshot,
      # transform through intervening versions, verify against current content,
      # and return ops with pre-resolved ranges. Advances the working snapshot
      # after each op so sequential ops see prior results.
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

        working_base = base_version.content_markdown
        verification_content = current_content.dup
        rebased_ops = []

        operations.each do |op|
          op = op.respond_to?(:to_unsafe_h) ? op.to_unsafe_h.transform_keys(&:to_s) : op.transform_keys(&:to_s)
          begin
            resolution = Plans::PositionResolver.call(content: working_base, operation: op)
            transformed_ranges = resolution.ranges.map do |range|
              Plans::TransformRange.transform_through_versions(range, intervening_versions)
            end

            if op["op"] == "replace_exact" && op["old_text"]
              transformed_ranges.each do |tr|
                actual = verification_content[tr[0]...tr[1]]
                unless actual == op["old_text"]
                  render json: {
                    error: "Conflict: text at target position has changed",
                    current_revision: @plan.current_revision,
                    expected: op["old_text"],
                    found: actual
                  }, status: :conflict
                  return
                end
              end
            end

            # Advance the working base snapshot so the next op resolves
            # against the result of this one (sequential semantics).
            apply_result = Plans::ApplyOperations.call(content: working_base, operations: [op])
            working_base = apply_result[:content]

            rebased_op = op.dup
            rebased_op["_pre_resolved_ranges"] = transformed_ranges
            rebased_ops << rebased_op

            # Advance verification content so the next op's conflict check
            # runs against the incrementally updated snapshot.
            verify_step = Plans::ApplyOperations.call(content: verification_content, operations: [rebased_op])
            verification_content = verify_step[:content]
          rescue Plans::TransformRange::Conflict => e
            render json: {
              error: "Conflict: #{e.message}",
              current_revision: @plan.current_revision
            }, status: :conflict
            return
          end
        end

        rebased_ops
      end

      def create_version_from_operations(operations, base_revision:)
        ActiveRecord::Base.transaction do
          @plan.lock!
          @plan.reload

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

        version = PlanVersion.create!(
          plan: @plan,
          organization: current_organization,
          revision: new_revision,
          content_markdown: result[:content],
          actor_type: ApiToken::HOLDER_TYPE,
          actor_id: @api_token.id,
          change_summary: params[:change_summary],
          diff_unified: diff.presence,
          operations_json: result[:applied],
          base_revision: params[:base_revision]&.to_i,
          reason: params[:reason]
        )

        @plan.update!(
          current_plan_version: version,
          current_revision: new_revision
        )

        @plan.comment_threads.mark_out_of_date_for_new_version!(version)

        broadcast_plan_update

        render json: {
          revision: new_revision,
          content_sha256: version.content_sha256,
          applied: result[:applied].length,
          version_id: version.id
        }, status: :created
      end

      def broadcast_plan_update
        Turbo::StreamsChannel.broadcast_replace_to(
          @plan,
          target: "plan-header",
          partial: "plans/header",
          locals: { plan: @plan }
        )
      end
    end
  end
end
