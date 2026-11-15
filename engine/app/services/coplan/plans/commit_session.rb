module CoPlan
  module Plans
    # Commits an EditSession's accumulated operations as a single PlanVersion.
    #
    # If the session's base_revision is behind current_revision, its
    # operations are rebased through the intervening versions by
    # Plans::Rebase, the same rebase the operations API uses.
    class CommitSession
      class StaleSessionError < StandardError; end
      class SessionConflictError < StandardError; end
      class SessionNotOpenError < StandardError; end

      SEMANTIC_KEYS = %w[op old_text new_text heading content needle occurrence replace_all count new_content include_heading].freeze

      # actor_id/agent_name: the session row keys ownership by the caller's
      # transient id (an API token), which names nobody in the history tab.
      # The committing controller passes the resolved user and agent so the
      # version is attributed the way comments are; direct Ruby callers
      # (cloud personas) fall back to the session's own actor fields.
      def self.call(session:, change_summary: nil, actor_id: nil, agent_name: nil, api_token_id: nil, reader_type: nil, reader_id: nil)
        new(session:, change_summary:, actor_id:, agent_name:, api_token_id:, reader_type:, reader_id:).call
      end

      def initialize(session:, change_summary: nil, actor_id: nil, agent_name: nil, api_token_id: nil, reader_type: nil, reader_id: nil)
        @session = session
        @change_summary = change_summary || session.change_summary
        @actor_id = actor_id || session.actor_id
        @agent_name = agent_name
        @api_token_id = api_token_id
        # Whose reads count for the human-edit fence. A live commit passes
        # the credential making the request; the expiry job has no request,
        # so it falls back to the session's owner. A human-actor session
        # isn't fenced at all.
        @reader_type = reader_type || (session.actor_type == "human" ? nil : "api_token")
        @reader_id = reader_id || (session.actor_type == "human" ? nil : session.actor_id)
      end

      def call
        raise SessionNotOpenError, "Session is not open" unless @session.open?

        plan = @session.plan

        ActiveRecord::Base.transaction do
          @session.lock!
          raise SessionNotOpenError, "Session is not open" unless @session.open?

          # No operations: just mark committed, no version created
          unless @session.has_operations?
            @session.update!(status: "committed", committed_at: Time.current)
            return { session: @session, version: nil }
          end

          plan.lock!
          EditLease.enforce!(plan: plan)

          # Under the lock, and on every route into this service — the
          # expiry job commits sessions with no request behind them, so a
          # controller-level check alone would let an abandoned session
          # rebase straight over a hand edit.
          Plans::HumanEditGuard.enforce!(
            plan: plan, reader_type: @reader_type, reader_id: @reader_id,
            base_revision: @session.base_revision
          )

          base_revision = @session.base_revision
          current_revision = plan.current_revision
          current_content = plan.current_content || ""

          # Determine the content to use as the result
          if base_revision == current_revision
            # No intervening edits — use draft_content directly
            new_content = @session.draft_content || current_content
            final_ops = @session.operations_json
          else
            # Stale! Need to rebase through intervening versions
            stale_gap = current_revision - base_revision
            if stale_gap > 20
              raise StaleSessionError, "Session is too stale (#{stale_gap} revisions behind, max 20)"
            end

            # Get intervening versions
            intervening_versions = plan.plan_versions
              .where("revision > ? AND revision <= ?", base_revision, current_revision)
              .order(revision: :asc)
              .to_a

            base_version = plan.plan_versions.find_by(revision: base_revision)
            raise SessionConflictError, "Base revision #{base_revision} not found" unless base_version

            # Each stored range was resolved against the session draft as it
            # stood before that operation: the base with the earlier session
            # operations applied. That is the content Plans::Rebase resolves
            # against, so the stored ranges are used as they are.
            operations = @session.operations_json.map do |op_data|
              op_data = op_data.transform_keys(&:to_s)
              semantic_op = op_data.slice(*SEMANTIC_KEYS)

              recorded_ranges = if op_data["resolved_range"]
                [ op_data["resolved_range"] ]
              elsif op_data.key?("replacements")
                op_data["replacements"].map { |rep| rep["resolved_range"] }
              end
              recorded_ranges ? semantic_op.merge("_pre_resolved_ranges" => recorded_ranges) : semantic_op
            end

            begin
              rebased_ops = Plans::Rebase.call(
                base_content: base_version.content_markdown,
                operations: operations,
                intervening_versions: intervening_versions,
                current_content: current_content
              )
            rescue Plans::Rebase::Conflict => e
              raise SessionConflictError, "Conflict during rebase: #{e.message}"
            end

            result = Plans::ApplyOperations.call(content: current_content, operations: rebased_ops)
            new_content = result[:content]
            final_ops = result[:applied]
          end

          # Create the version
          new_revision = plan.current_revision + 1
          diff = Diffy::Diff.new(current_content, new_content).to_s

          version = PlanVersion.create_for_commit!(
            plan: plan,
            revision: new_revision,
            content_markdown: new_content,
            actor_type: @session.actor_type,
            actor_id: @actor_id,
            agent_name: @agent_name,
            api_token_id: @api_token_id,
            change_summary: @change_summary,
            diff_unified: diff.presence,
            operations_json: final_ops,
            base_revision: @session.base_revision
          )

          Plans::AdvanceVersion.call(plan: plan, version: version)

          plan.comment_threads.mark_out_of_date_for_new_version!(version)

          @session.update!(
            status: "committed",
            committed_at: Time.current,
            plan_version_id: version.id,
            change_summary: @change_summary
          )

          # Broadcast update
          Broadcaster.replace_to(
            plan,
            target: "plan-header",
            partial: "coplan/plans/header",
            locals: { plan: plan }
          )
          Broadcaster.replace_plan_content(plan)

          { session: @session, version: version }
        end
      end
    end
  end
end
