module CoPlan
  module Plans
    # Toggles one task-list checkbox as a first-class version commit: the
    # same lock → revision check → ApplyOperations → PlanVersion pipeline
    # as ReplaceContent, but for a caller that already knows the surgical
    # replace_exact edit instead of supplying a whole document.
    class ToggleCheckbox
      # Raised when the optional line guard fails: the rendered checkbox
      # carries its 1-based source line, and the line's text must equal
      # old_text — line and text must both agree so duplicate task lines
      # elsewhere can't collide and a stale client fails loudly instead of
      # toggling a lookalike.
      class LineMismatchError < OperationError
        attr_reader :current_revision
        def initialize(message, current_revision:)
          super(message)
          @current_revision = current_revision
        end
      end

      def self.call(plan:, old_text:, new_text:, base_revision:, actor_id:, line: nil)
        new(
          plan: plan,
          old_text: old_text,
          new_text: new_text,
          base_revision: base_revision,
          actor_id: actor_id,
          line: line
        ).call
      end

      def initialize(plan:, old_text:, new_text:, base_revision:, actor_id:, line: nil)
        @plan = plan
        @old_text = old_text
        @new_text = new_text
        @base_revision = base_revision
        @actor_id = actor_id
        @line = line
      end

      def call
        ActiveRecord::Base.transaction do
          @plan.lock!
          @plan.reload

          if @plan.current_revision != @base_revision
            raise ReplaceContent::StaleRevisionError.new(
              "Stale revision. Expected #{@plan.current_revision}, got #{@base_revision}",
              current_revision: @plan.current_revision
            )
          end

          current_content = @plan.current_content || ""
          operation = { "op" => "replace_exact", "old_text" => @old_text, "new_text" => @new_text }
          if @line
            occurrence = occurrence_at_line(current_content, @old_text, @line)
            if occurrence.nil?
              raise LineMismatchError.new(
                "old_text does not match line #{@line}",
                current_revision: @plan.current_revision
              )
            end
            operation["occurrence"] = occurrence
          end

          result = Plans::ApplyOperations.call(content: current_content, operations: [ operation ])

          new_revision = @plan.current_revision + 1
          diff = Diffy::Diff.new(current_content, result[:content]).to_s

          version = PlanVersion.create!(
            plan: @plan,
            revision: new_revision,
            content_markdown: result[:content],
            actor_type: "human",
            actor_id: @actor_id,
            change_summary: "Toggle checkbox",
            diff_unified: diff.presence,
            operations_json: result[:applied],
            base_revision: @base_revision
          )

          @plan.update!(current_plan_version: version, current_revision: new_revision)
          @plan.comment_threads.mark_out_of_date_for_new_version!(version)

          Broadcaster.replace_to(
            @plan,
            target: "plan-header",
            partial: "coplan/plans/header",
            locals: { plan: @plan }
          )
          Broadcaster.replace_plan_content(@plan)

          { version: version, plan: @plan }
        end
      end

      private

      # Maps a verified (line, old_text) pair to the occurrence ordinal the
      # position resolver will select, keeping the toggle a plain
      # replace_exact. Returns nil unless the line's rstripped text is
      # exactly old_text.
      def occurrence_at_line(content, old_text, line)
        lines = content.each_line.to_a
        return nil if line > lines.length
        return nil unless lines[line - 1].rstrip == old_text

        line_start = lines.first(line - 1).sum(&:length)
        occurrence = 1
        pos = 0
        while (idx = content.index(old_text, pos)) && idx < line_start
          occurrence += 1
          pos = idx + old_text.length
        end
        occurrence
      end
    end
  end
end
