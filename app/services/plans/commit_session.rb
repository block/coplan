module Plans
  class CommitSession
    class StaleSessionError < StandardError; end
    class SessionConflictError < StandardError; end
    class SessionNotOpenError < StandardError; end

    def self.call(session:, change_summary: nil)
      new(session:, change_summary:).call
    end

    def initialize(session:, change_summary: nil)
      @session = session
      @change_summary = change_summary || session.change_summary
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

          # Transform each operation's resolved positions through intervening edits,
          # then re-apply using the transformed positions (not re-resolving from scratch)
          verification_content = current_content.dup
          rebased_ops = []
          @session.operations_json.each do |op_data|
            op_data = op_data.transform_keys(&:to_s)
            semantic_keys = %w[op old_text new_text heading content needle occurrence replace_all count]
            semantic_op = op_data.slice(*semantic_keys)

            if op_data["resolved_range"]
              begin
                transformed_range = Plans::TransformRange.transform_through_versions(
                  op_data["resolved_range"], intervening_versions
                )
              rescue Plans::TransformRange::Conflict => e
                raise SessionConflictError, "Conflict during rebase: #{e.message}"
              end

              verify_text_at_range!(verification_content, transformed_range, op_data)
              semantic_op["_pre_resolved_ranges"] = [transformed_range]
            elsif op_data.key?("replacements")
              transformed_ranges = op_data["replacements"].map do |rep|
                begin
                  Plans::TransformRange.transform_through_versions(
                    rep["resolved_range"], intervening_versions
                  )
                rescue Plans::TransformRange::Conflict => e
                  raise SessionConflictError, "Conflict during rebase: #{e.message}"
                end
              end

              transformed_ranges.each { |tr| verify_text_at_range!(verification_content, tr, op_data) }
              semantic_op["_pre_resolved_ranges"] = transformed_ranges
            end

            rebased_ops << semantic_op

            # Advance verification content so subsequent ops verify against
            # the incrementally updated snapshot (not the original current_content).
            step = Plans::ApplyOperations.call(content: verification_content, operations: [semantic_op])
            verification_content = step[:content]
          end

          result = Plans::ApplyOperations.call(content: current_content, operations: rebased_ops)
          new_content = result[:content]
          final_ops = result[:applied]
        end

        # Create the version
        new_revision = plan.current_revision + 1
        diff = Diffy::Diff.new(current_content, new_content).to_s

        version = PlanVersion.create!(
          plan: plan,
          organization: @session.organization,
          revision: new_revision,
          content_markdown: new_content,
          actor_type: @session.actor_type,
          actor_id: @session.actor_id,
          change_summary: @change_summary,
          diff_unified: diff.presence,
          operations_json: final_ops,
          base_revision: @session.base_revision
        )

        plan.update!(
          current_plan_version: version,
          current_revision: new_revision
        )

        plan.comment_threads.mark_out_of_date_for_new_version!(version)

        @session.update!(
          status: "committed",
          committed_at: Time.current,
          plan_version_id: version.id,
          change_summary: @change_summary
        )

        # Broadcast update
        Turbo::StreamsChannel.broadcast_replace_to(
          plan,
          target: "plan-header",
          partial: "plans/header",
          locals: { plan: plan }
        )

        { session: @session, version: version }
      end
    end

    private

    def verify_text_at_range!(content, range, op_data)
      return unless op_data["op"] == "replace_exact" && op_data["old_text"]

      actual_text = content[range[0]...range[1]]
      return if actual_text == op_data["old_text"]

      context_start = [range[0] - 200, 0].max
      context_end = [range[1] + 200, content.length].min
      raise SessionConflictError,
        "Content changed at conflict region. Expected '#{op_data["old_text"]}' " \
        "but found '#{actual_text}'. Context: ...#{content[context_start...context_end]}..."
    end
  end
end
