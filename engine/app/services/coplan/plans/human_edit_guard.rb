module CoPlan
  module Plans
    # Human edits are a fence, not a merge input.
    #
    # The rest of the concurrency machinery treats every revision the same:
    # a stale agent write gets transformed through whatever landed in
    # between (Plans::TransformRange) and applied anyway. That's the right
    # behavior for agent-vs-agent races — two agents editing different
    # paragraphs shouldn't block each other.
    #
    # It is the wrong behavior when the intervening edit came from a person.
    # Someone opening the editor and changing the words by hand is the
    # highest-authority input the document gets, and an agent that never saw
    # those words can silently undo them — rewriting the paragraph the human
    # just fixed, restoring the sentence they just cut. So: if a human has
    # edited since this caller last actually read the plan, every agent
    # write is refused until the caller pulls the new content.
    #
    # "Actually read" means a read receipt (CoPlan::PlanRead), not a
    # `base_revision` the caller asserts — an agent handed a 409 that names
    # the current revision could otherwise just echo the number back and
    # clobber the edit on the retry.
    #
    # The refusal carries the human's diff. An agent that's told only "you
    # are stale" re-reads and re-derives; an agent that's shown the words a
    # person chose can keep them.
    class HumanEditGuard
      # Blocking is only useful if the message is actionable, and a diff is
      # the actionable part — but a wholesale rewrite of a long plan would
      # otherwise dump the entire document into an error body.
      MAX_DIFF_CHARS = 6_000
      MAX_TOTAL_DIFF_CHARS = 12_000
      # Beyond this, listing every edit stops helping; the caller needs to
      # re-read the plan regardless.
      MAX_EDITS_LISTED = 10

      # Raised by .enforce!. Carries the same payload .call returns, so a
      # controller can render it identically wherever the block is caught.
      class Blocked < StandardError
        attr_reader :payload

        def initialize(payload)
          @payload = payload
          super(payload[:error])
        end
      end

      # Returns nil when the write may proceed, or a JSON-ready Hash
      # describing the block (render it with status :conflict).
      #
      # Call this early — before a request does any work — for a fast,
      # informative refusal. It is NOT the enforcement point: a human edit
      # can land between this check and the write. Use .enforce! inside the
      # plan-locked transaction for that.
      def self.call(plan:, reader_type:, reader_id:, base_revision: nil)
        new(plan: plan, reader_type: reader_type, reader_id: reader_id, base_revision: base_revision).call
      end

      # The enforcement point. Must be called inside the same transaction
      # that holds the plan lock and creates the version, so no human
      # revision can land between the check and the write — otherwise the
      # rebase machinery downstream would happily merge the agent's edit
      # past a hand edit that arrived microseconds too late.
      #
      # A blank reader identity means the caller isn't an agent (a human
      # editing in the web UI, a system write); the fence doesn't apply.
      def self.enforce!(plan:, reader_type:, reader_id:, base_revision: nil)
        return if reader_type.blank? || reader_id.blank?

        payload = call(plan: plan, reader_type: reader_type, reader_id: reader_id, base_revision: base_revision)
        raise Blocked, payload if payload
      end

      def initialize(plan:, reader_type:, reader_id:, base_revision: nil)
        @plan = plan
        @reader_type = reader_type
        @reader_id = reader_id
        @base_revision = base_revision
      end

      # The common case is "no human has touched this plan since you read
      # it", and it has to stay cheap: one aggregate over the version index,
      # no rows loaded. Only a genuine block pays for fetching versions.
      def call
        last_human_revision = @plan.plan_versions.where(actor_type: "human").maximum(:revision)
        return nil if last_human_revision.nil?
        return nil if seen_revision >= last_human_revision

        conflict_payload(last_human_revision, unseen_human_versions)
      end

      private

      # content_markdown is a MEDIUMTEXT per row and we never look at it —
      # the diff is what the caller needs. Select around it.
      def unseen_human_versions
        @plan.plan_versions
          .where(actor_type: "human")
          .where("revision > ?", seen_revision)
          .order(revision: :asc)
          .select(:id, :plan_id, :revision, :actor_id, :change_summary, :diff_unified, :created_at)
          .includes(:actor_user)
          .to_a
      end

      def seen_revision
        @seen_revision ||= PlanRead.revision_for(
          plan: @plan, reader_type: @reader_type, reader_id: @reader_id
        )
      end

      def conflict_payload(last_human_revision, unseen)
        listed = unseen.last(MAX_EDITS_LISTED)

        {
          error: error_message(unseen),
          code: "human_edit_pending",
          current_revision: @plan.current_revision,
          last_human_revision: last_human_revision,
          last_seen_revision: seen_revision,
          base_revision: @base_revision,
          human_edits: with_diff_budget(listed),
          human_edits_omitted: (unseen.length - listed.length).presence,
          resolve: resolve_instructions
        }.compact
      end

      def error_message(unseen)
        editors = unseen.filter_map { |v| v.actor_user&.name }.uniq
        who = if editors.length == 1
          editors.first
        elsif editors.length > 1
          "#{editors[0..-2].join(", ")} and #{editors.last}"
        else
          "Someone"
        end

        count = unseen.length
        edits = count == 1 ? "an edit" : "#{count} edits"
        seen = seen_revision.zero? ? "you have never read this plan" : "you last read v#{seen_revision}"

        "Blocked: #{who} edited this plan by hand (#{edits}, now at v#{@plan.current_revision}) and " \
        "#{seen}. A person's direct edit outranks an agent's — it is not something to merge past. " \
        "Read the current content, keep their changes, fold your own work in around them, then write again."
      end

      # Diffs are included newest-first so the most recent human intent
      # survives the budget; the list is re-sorted into revision order for
      # reading.
      def with_diff_budget(versions)
        budget = MAX_TOTAL_DIFF_CHARS
        by_revision = {}

        versions.reverse_each do |version|
          diff, budget = clip_diff(version.diff_unified, budget)
          by_revision[version.revision] = {
            revision: version.revision,
            editor: version.actor_user&.name,
            edited_at: version.created_at,
            change_summary: version.change_summary,
            diff: diff
          }.compact
        end

        by_revision.keys.sort.map { |rev| by_revision[rev] }
      end

      def clip_diff(diff, budget)
        return [ nil, budget ] if diff.blank? || budget <= 0

        limit = [ MAX_DIFF_CHARS, budget ].min
        if diff.length <= limit
          [ diff, budget - diff.length ]
        else
          [ "#{diff[0, limit]}\n… diff truncated — read the plan for the full text.", budget - limit ]
        end
      end

      def resolve_instructions
        base = CoPlan::Engine.routes.url_helpers.snapshot_api_v1_plan_path(@plan)
        "GET #{base} to pull the current content (that read is what lifts this block), " \
        "then re-send your write with base_revision=#{@plan.current_revision}. " \
        "Do not re-send your previous body unchanged — it predates the human's edit."
      end
    end
  end
end
