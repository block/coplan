module CoPlan
  module Plans
    # Checks a stale operation after its range has been transformed through
    # intervening versions. The operations API and edit-session commits both
    # rebase this way, so both use this one check.
    class Rebase
      class Conflict < StandardError
        attr_reader :expected, :found

        def initialize(message, expected:, found:)
          @expected = expected
          @found = found
          super("#{message}: expected #{excerpt(expected)}, found #{excerpt(found)}")
        end

        private

        def excerpt(text)
          text.to_s.truncate(200).inspect
        end
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
    end
  end
end
