module CoPlan
  module Plans
    # Replaces a plan's content wholesale by diffing the supplied new_content
    # against the plan's current_content, decomposing the diff into a series
    # of replace_exact operations, applying them through Plans::ApplyOperations
    # (so each gets resolved_range/new_range positional metadata), and
    # persisting the result as a new immutable PlanVersion.
    #
    # Why this matters: agents are great at producing whole files. Letting
    # them PUT the entire updated markdown is much simpler than scripting
    # surgical operations, and the line-level diff preserves comment anchors
    # in unchanged regions via the existing OT engine.
    #
    # Concurrency model: optimistic via base_revision. If the plan's
    # current_revision has advanced beyond the supplied base_revision, this
    # raises StaleRevisionError — the caller should re-read the plan and
    # rebase their edits. We don't auto-rebase: a wholesale rewrite that
    # didn't see intervening edits would silently clobber them.
    class ReplaceContent
      class StaleRevisionError < StandardError
        attr_reader :current_revision
        def initialize(message, current_revision:)
          super(message)
          @current_revision = current_revision
        end
      end

      # Raised when DiffToOperations + ApplyOperations don't reproduce the
      # caller's new_content exactly — indicates a bug in the diff pipeline.
      # Surfaces as a 500 (rather than silently persisting wrong content).
      class RoundtripFailureError < StandardError; end

      def self.call(plan:, new_content:, base_revision:, actor_type:, actor_id:, change_summary: nil, reason: nil)
        new(
          plan: plan,
          new_content: new_content,
          base_revision: base_revision,
          actor_type: actor_type,
          actor_id: actor_id,
          change_summary: change_summary,
          reason: reason
        ).call
      end

      def initialize(plan:, new_content:, base_revision:, actor_type:, actor_id:, change_summary: nil, reason: nil)
        @plan = plan
        # Normalize line endings to LF before diffing. Browser textareas, agents
        # running on Windows, and copy-paste from various sources commonly emit
        # CRLF (`\r\n`). If the stored current_content is LF and the inbound
        # new_content is CRLF, every line would diff as changed — producing
        # a single wholesale-rewrite op that destroys all comment anchors and
        # bloats operations_json. Stripping `\r` keeps the diff focused on
        # actual content changes.
        @new_content = (new_content || "").delete("\r")
        @base_revision = base_revision
        @actor_type = actor_type
        @actor_id = actor_id
        @change_summary = change_summary
        @reason = reason
      end

      def call
        ActiveRecord::Base.transaction do
          @plan.lock!
          @plan.reload

          if @plan.current_revision != @base_revision
            raise StaleRevisionError.new(
              "Stale revision. Expected #{@plan.current_revision}, got #{@base_revision}",
              current_revision: @plan.current_revision
            )
          end

          current_content = @plan.current_content || ""

          # No-op: content is identical → no version, no broadcasts.
          if current_content == @new_content
            return { version: nil, plan: @plan, applied: 0, no_op: true }
          end

          ops = Plans::DiffToOperations.call(
            old_content: current_content,
            new_content: @new_content
          )

          result = Plans::ApplyOperations.call(content: current_content, operations: ops)

          # Sanity: ApplyOperations must produce exactly the requested content.
          # If this ever fires, DiffToOperations has a bug — better to fail
          # loudly than silently corrupt the version.
          unless result[:content] == @new_content
            raise RoundtripFailureError, "DiffToOperations roundtrip failure for plan #{@plan.id}"
          end

          new_revision = @plan.current_revision + 1
          diff = Diffy::Diff.new(current_content, @new_content).to_s

          version = PlanVersion.create!(
            plan: @plan,
            revision: new_revision,
            content_markdown: @new_content,
            actor_type: @actor_type,
            actor_id: @actor_id,
            change_summary: @change_summary,
            diff_unified: diff.presence,
            operations_json: result[:applied],
            base_revision: @base_revision,
            reason: @reason
          )

          @plan.update!(
            current_plan_version: version,
            current_revision: new_revision
          )

          @plan.comment_threads.mark_out_of_date_for_new_version!(version)

          Broadcaster.replace_to(
            @plan,
            target: "plan-header",
            partial: "coplan/plans/header",
            locals: { plan: @plan }
          )

          { version: version, plan: @plan, applied: result[:applied].length, no_op: false }
        end
      end
    end
  end
end
