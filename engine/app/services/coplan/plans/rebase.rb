module CoPlan
  module Plans
    # Rebases a stale list of operations through the versions written since
    # its base. The operations API and edit-session commits both use it.
    #
    # Each operation is resolved against the base with the earlier
    # operations applied (working_base). The intervening edits are kept in
    # that same coordinate space: after each operation, every remaining
    # edit is moved past the operation's own edits. An operation's ranges
    # therefore always meet edits measured against the same content.
    #
    # Returns the operations with "_pre_resolved_ranges" pointing into
    # current_content (with the earlier rebased operations applied), ready
    # for Plans::ApplyOperations. Raises Conflict when an intervening edit
    # overlaps an operation's target or its target text no longer matches.
    class Rebase
      class Conflict < StandardError
        attr_reader :expected, :found

        def initialize(message, expected: nil, found: nil)
          @expected = expected
          @found = found
          message = "#{message}: expected #{excerpt(expected)}, found #{excerpt(found)}" unless expected.nil? && found.nil?
          super(message)
        end

        private

        def excerpt(text)
          text.to_s.truncate(200).inspect
        end
      end

      # operations: string- or symbol-keyed hashes. An operation that
      # carries "_pre_resolved_ranges" is already resolved against
      # working_base; the others are resolved here.
      def self.call(base_content:, operations:, intervening_versions:, current_content:)
        new(base_content:, operations:, intervening_versions:, current_content:).call
      end

      def initialize(base_content:, operations:, intervening_versions:, current_content:)
        @base_content = base_content
        @operations = operations
        @intervening_versions = intervening_versions
        @current_content = current_content
      end

      def call
        edits = TransformRange.edits_from_versions(@intervening_versions)
        working_base = @base_content
        verification_content = @current_content

        @operations.map do |op|
          op = op.transform_keys(&:to_s)
          ranges = op["_pre_resolved_ranges"] || PositionResolver.call(content: working_base, operation: op).ranges
          transformed_ranges = ranges.map { |range| TransformRange.transform_through_edits(range, edits) }

          ranges.zip(transformed_ranges).each do |range, transformed|
            self.class.verify!(op, working_base[range[0]...range[1]], verification_content, transformed)
          end

          base_step = ApplyOperations.call(content: working_base, operations: [ op.merge("_pre_resolved_ranges" => ranges) ])
          working_base = base_step[:content]
          edits = move_past(edits, TransformRange.edits_from_operations(base_step[:applied]))

          rebased_op = op.merge("_pre_resolved_ranges" => transformed_ranges)
          verification_content = ApplyOperations.call(content: verification_content, operations: [ rebased_op ])[:content]
          rebased_op
        end
      rescue TransformRange::Conflict => e
        raise Conflict, e.message
      end

      # +expected_text+ is what the operation covered when it was resolved;
      # +range+ is that span transformed into +current_content+.
      def self.verify!(op, expected_text, current_content, range)
        verify_target!(expected_text, current_content, range)
        verify_heading_anchor!(op, current_content, range)
      end

      # The transformed span must hold exactly the text the operation
      # targeted. Anything else means the span moved or its text changed,
      # and applying the operation there would edit the wrong text.
      def self.verify_target!(expected_text, current_content, range)
        found = current_content[range[0]...range[1]]
        return if found == expected_text

        raise Conflict.new("Text at target position has changed", expected: expected_text, found: found)
      end

      # An insert under a heading, or a body-only section replacement, does
      # not cover its heading. An intervening rename of that heading ends
      # right before the target, so the span moves cleanly and its text still
      # matches. Check the heading line in front of the target as well.
      def self.verify_heading_anchor!(op, current_content, range)
        heading = case op["op"]
        when "insert_under_heading" then op["heading"]
        when "replace_section" then op["heading"] unless include_heading?(op)
        end
        return if heading.nil?

        line_end = range[0]
        line_end -= 1 while line_end > 0 && current_content[line_end - 1] == "\n"
        line_start = line_end > 0 ? (current_content.rindex("\n", line_end - 1) || -1) + 1 : 0
        found = current_content[line_start...line_end]
        return if found.rstrip == heading.rstrip

        raise Conflict.new("Heading changed: the heading before the target position no longer matches", expected: heading, found: found)
      end

      def self.include_heading?(op)
        value = op.fetch("include_heading", true)
        value != false && value != "false"
      end
      private_class_method :include_heading?

      private

      # +edits+ and +op_edits+ are both sequences against the same content.
      # Returns +edits+ as they apply after +op_edits+.
      def move_past(edits, op_edits)
        edits.map do |edit|
          op_edits = op_edits.map do |op_edit|
            edit, moved_op_edit = TransformRange.exchange(edit, op_edit)
            moved_op_edit
          end
          edit
        end
      end
    end
  end
end
