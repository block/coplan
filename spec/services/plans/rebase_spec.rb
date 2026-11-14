require "rails_helper"

RSpec.describe CoPlan::Plans::Rebase do
  describe ".verify!" do
    let(:content) { "# Plan\n\n## Goals\n\nShip it.\n\n## Risks\n\nNone." }

    it "accepts a span that still holds exactly the targeted text" do
      start = content.index("Ship it.\n\n")
      expect {
        described_class.verify!({ "op" => "delete_paragraph_containing", "needle" => "Ship" }, "Ship it.\n\n", content, [ start, start + 10 ])
      }.not_to raise_error
    end

    it "refuses a span that only contains the needle" do
      start = content.index("Ship it.")
      error = nil
      expect {
        described_class.verify!({ "op" => "delete_paragraph_containing", "needle" => "Ship" }, "Ship it.\n\n", content, [ start, start + 8 ])
      }.to raise_error(described_class::Conflict) { |e| error = e }
      expect(error.expected).to eq("Ship it.\n\n")
      expect(error.found).to eq("Ship it.")
    end

    it "refuses an insert whose heading was renamed" do
      renamed = content.sub("## Goals", "## Objectives")
      point = renamed.index("## Objectives") + "## Objectives".length
      expect {
        described_class.verify!({ "op" => "insert_under_heading", "heading" => "## Goals", "content" => "x" }, "", renamed, [ point, point ])
      }.to raise_error(described_class::Conflict, /heading/)
    end

    it "refuses a body-only section replacement whose heading was renamed" do
      renamed = content.sub("## Goals", "## Objectives")
      start = renamed.index("Ship it.")
      op = { "op" => "replace_section", "heading" => "## Goals", "new_content" => "x", "include_heading" => false }
      expect {
        described_class.verify!(op, "Ship it.", renamed, [ start, start + 8 ])
      }.to raise_error(described_class::Conflict, /heading/)
      expect {
        described_class.verify!(op, "Ship it.", content, [ content.index("Ship it."), content.index("Ship it.") + 8 ])
      }.not_to raise_error
    end
  end

  describe ".call" do
    def rebase(base, operations, intervening_operations, current)
      described_class.call(
        base_content: base,
        operations: operations,
        intervening_versions: intervening_operations.map { |ops| { operations_json: ops } },
        current_content: current
      )
    end

    def apply(content, operations)
      CoPlan::Plans::ApplyOperations.call(content: content, operations: operations)
    end

    it "keeps a later operation in place when an earlier one changes the length" do
      base = "AAAA\n\nBBBB\n\nCCCC"
      expanded = "AAAA expanded into a forty-char sentence"
      # Another agent inserted "XX" inside CCCC.
      intervening = apply(base, [ { "op" => "replace_exact", "old_text" => "", "new_text" => "XX", "_pre_resolved_ranges" => [ [ 14, 14 ] ] } ])

      rebased = rebase(base, [
        { "op" => "replace_exact", "old_text" => "AAAA", "new_text" => expanded },
        { "op" => "delete_paragraph_containing", "needle" => "BBBB" }
      ], [ intervening[:applied] ], intervening[:content])

      expect(apply(intervening[:content], rebased)[:content]).to eq("#{expanded}\n\nCCXXCC")
    end

    it "tracks padding added when rebasing an empty section before a later target" do
      base = "# H\n# Next\n\nAB"
      intervening = apply(base, [ { "op" => "replace_exact", "old_text" => "# H\n", "new_text" => "# H" } ])
      operations = [
        { "op" => "replace_section", "heading" => "# H", "include_heading" => false, "new_content" => "body" },
        { "op" => "replace_exact", "old_text" => "AB", "new_text" => "CD" }
      ]

      rebased = rebase(base, operations, [ intervening[:applied] ], intervening[:content])

      expect(apply(intervening[:content], rebased)[:content]).to eq("# H\nbody\n# Next\n\nCD")
    end

    it "does not mistake repeated text for a shifted target after section padding" do
      base = "# H\n# Next\n\naaa"
      intervening = apply(base, [ { "op" => "replace_exact", "old_text" => "# H\n", "new_text" => "# H" } ])
      operations = [
        { "op" => "replace_section", "heading" => "# H", "include_heading" => false, "new_content" => "body" },
        { "op" => "replace_exact", "old_text" => "a", "new_text" => "Z", "occurrence" => 2 }
      ]

      rebased = rebase(base, operations, [ intervening[:applied] ], intervening[:content])

      expect(apply(intervening[:content], rebased)[:content]).to eq("# H\nbody\n# Next\n\naZa")
    end

    [ "body", "body\n", "\nbody", "", "\n" ].each do |body|
      it "tracks empty-section padding for #{body.inspect} and stored later ranges" do
        base = "# H\n# Next\n\naaa"
        intervening = apply(base, [ { "op" => "replace_exact", "old_text" => "# H\n", "new_text" => "# H" } ])
        staged = apply(base, [
          { "op" => "replace_section", "heading" => "# H", "include_heading" => "false", "new_content" => body },
          { "op" => "replace_exact", "old_text" => "a", "new_text" => "Z", "occurrence" => 2 },
          { "op" => "replace_exact", "old_text" => "Z", "new_text" => "YY" }
        ])
        operations = staged[:applied].map { |op| op.merge("_pre_resolved_ranges" => [ op.fetch("resolved_range") ]) }

        rebased = rebase(base, operations, [ intervening[:applied] ], intervening[:content])

        separator = body.empty? || body.end_with?("\n") ? "" : "\n"
        expect(apply(intervening[:content], rebased)[:content]).to eq("# H\n#{body}#{separator}# Next\n\naYYa")
      end
    end

    it "tracks padding removed at EOF before editing the newly inserted body" do
      base = "# H"
      # Record the intervening insertion alone, so it does not replace the
      # heading/insert point. This is the metadata a character diff emits.
      intervening = apply(base, [ { "op" => "replace_exact", "old_text" => "", "new_text" => "\n", "_pre_resolved_ranges" => [ [ 3, 3 ] ] } ])
      operations = [
        { "op" => "replace_section", "heading" => "# H", "include_heading" => false, "new_content" => "body" },
        { "op" => "replace_exact", "old_text" => "body", "new_text" => "updated" }
      ]

      rebased = rebase(base, operations, [ intervening[:applied] ], intervening[:content])

      expect(apply(intervening[:content], rebased)[:content]).to eq("# H\nupdated")
    end

    it "keeps same-position stored inserts ordered through a later operation" do
      base = "AB"
      intervening = apply(base, [ { "op" => "replace_exact", "old_text" => "", "new_text" => "X", "_pre_resolved_ranges" => [ [ 1, 1 ] ] } ])
      operations = [
        { "op" => "replace_exact", "old_text" => "", "new_text" => "Y", "_pre_resolved_ranges" => [ [ 1, 1 ] ] },
        { "op" => "replace_exact", "old_text" => "B", "new_text" => "Z" }
      ]

      rebased = rebase(base, operations, [ intervening[:applied] ], intervening[:content])

      expect(apply(intervening[:content], rebased)[:content]).to eq("AXYZ")
      expect(rebased.map { |op| op["_pre_resolved_ranges"] }).to eq([ [ [ 2, 2 ] ], [ [ 3, 4 ] ] ])
    end

    it "exchanges replace-all ranges through multiple operations and versions" do
      base = "AA middle AA tail"
      first = apply(base, [ { "op" => "replace_exact", "old_text" => "middle", "new_text" => "a longer middle" } ])
      second = apply(first[:content], [ { "op" => "replace_exact", "old_text" => "tail", "new_text" => "end" } ])
      operations = [
        { "op" => "replace_exact", "old_text" => "AA", "new_text" => "AAAAA", "replace_all" => true },
        { "op" => "replace_exact", "old_text" => "AAAAA", "new_text" => "Z", "occurrence" => 2 },
        { "op" => "replace_exact", "old_text" => "AAAAA", "new_text" => "Q" }
      ]

      rebased = rebase(base, operations, [ first[:applied], second[:applied] ], second[:content])

      expect(apply(second[:content], rebased)[:content]).to eq("Q a longer middle Z end")
    end

    it "preserves stored ranges when repeated text cannot be resolved again" do
      base = "same same tail"
      intervening = apply(base, [ { "op" => "replace_exact", "old_text" => "tail", "new_text" => "end" } ])
      operations = [ { "op" => "replace_exact", "old_text" => "same", "new_text" => "chosen", "_pre_resolved_ranges" => [ [ 5, 9 ] ] } ]

      rebased = rebase(base, operations, [ intervening[:applied] ], intervening[:content])

      expect(apply(intervening[:content], rebased)[:content]).to eq("same chosen end")
    end

    it "raises Conflict when an intervening edit overlaps the target" do
      base = "AAAA\n\nBBBB\n\nCCCC"
      intervening = apply(base, [ { "op" => "replace_exact", "old_text" => "BB", "new_text" => "ZZ", "_pre_resolved_ranges" => [ [ 7, 9 ] ] } ])

      expect {
        rebase(base, [ { "op" => "replace_exact", "old_text" => "BBBB", "new_text" => "Q" } ], [ intervening[:applied] ], intervening[:content])
      }.to raise_error(described_class::Conflict)
    end

    # Random documents, random intervening edits and random stale operation
    # lists. Every character carries an identity, so the correct result is
    # built from identities, independently of the code under test: each
    # operation replaces exactly the characters it targeted in its own
    # snapshot, and an insert lands right before the character that
    # followed it there. Every rebase must produce that result or raise
    # Conflict.
    describe "on random stale requests" do
      def random_text(rng, max)
        Array.new(rng.rand(0..max)) { "abxyz "[rng.rand(6)] }.join
      end

      def random_document(rng)
        words = %w[a b ab ba abc cab]
        blocks = Array.new(rng.rand(3..7)) do |i|
          rng.rand < 0.3 ? "## H#{i}" : Array.new(rng.rand(1..4)) { words[rng.rand(words.length)] }.join(" ")
        end
        "# Doc\n\n#{blocks.join("\n\n")}"
      end

      def valid?(content, op)
        CoPlan::Plans::PositionResolver.call(content: content, operation: op)
        true
      rescue CoPlan::Plans::OperationError
        false
      end

      def random_operation(rng, content)
        return nil if content.empty?

        20.times do
          op = case rng.rand(4)
          when 0
            start = rng.rand(content.length)
            old_text = content[start, rng.rand(1..8)]
            { "op" => "replace_exact", "old_text" => old_text, "new_text" => random_text(rng, 6) }
          when 1
            start = rng.rand(content.length)
            { "op" => "delete_paragraph_containing", "needle" => content[start, rng.rand(1..5)] }
          when 2
            heading = content.scan(/^## H\d+$/).sample(random: rng)
            heading && { "op" => "insert_under_heading", "heading" => heading, "content" => random_text(rng, 6) }
          else
            heading = content.scan(/^## H\d+$/).sample(random: rng)
            heading && { "op" => "replace_section", "heading" => heading, "new_content" => random_text(rng, 6) }
          end
          return op if op && valid?(content, op)
        end
        nil
      end

      # Applies one operation to text and to its [char, id] tokens. Returns
      # the new text and tokens, the ids it replaced, its new tokens, and
      # the id of the token that followed the replaced span.
      def apply_tracked(content, tokens, op, id)
        result = apply(content, [ op ])
        applied = result[:applied].first
        s, e = applied["resolved_range"]
        new_s, new_e = applied["new_range"]
        inserted = result[:content][new_s...new_e].chars.each_with_index.map { |char, i| [ char, "#{id}.#{i}" ] }
        [ result[:content], tokens[0...s] + inserted + tokens[e..], tokens[s...e].map(&:last), inserted, tokens[e]&.last, applied ]
      end

      def expected_tokens(current_tokens, targets)
        targets.reduce(current_tokens) do |tokens, (removed_ids, inserted, following_id)|
          if removed_ids.empty?
            at = following_id ? tokens.index { |token| token.last == following_id } : tokens.length
            return nil unless at
            tokens[0...at] + inserted + tokens[at..]
          else
            at = tokens.index { |token| token.last == removed_ids.first }
            return nil unless at && tokens[at, removed_ids.length].map(&:last) == removed_ids
            tokens[0...at] + inserted + tokens[(at + removed_ids.length)..]
          end
        end
      end

      it "either applies each operation to exactly its target or raises Conflict" do
        rng = Random.new(20_261_107)
        outcomes = Hash.new(0)

        500.times do |n|
          base = random_document(rng)
          base_tokens = base.chars.each_with_index.map { |char, i| [ char, "base.#{i}" ] }

          current = base
          current_tokens = base_tokens
          markers = []
          intervening = Array.new(rng.rand(1..3)) do |v|
            Array.new(rng.rand(1..2)) do |k|
              start = rng.rand(0..current.length)
              stop = [ start + rng.rand(0..4), current.length ].min
              marker = stop > start && rng.rand < 0.25 ? "" : "<#{v}.#{k}>"
              markers << marker unless marker.empty?
              op = { "op" => "replace_exact", "old_text" => current[start...stop], "new_text" => marker, "_pre_resolved_ranges" => [ [ start, stop ] ] }
              current, current_tokens, _, _, _, applied = apply_tracked(current, current_tokens, op, "edit#{v}.#{k}")
              applied
            end
          end

          working = base
          working_tokens = base_tokens
          operations = []
          targets = []
          rng.rand(1..4).times do |i|
            op = random_operation(rng, working)
            next unless op
            working, working_tokens, removed_ids, inserted, following_id, = apply_tracked(working, working_tokens, op, "op#{i}")
            operations << op
            targets << [ removed_ids, inserted, following_id ]
          end
          next if operations.empty?

          details = "case #{n}: base=#{base.inspect} current=#{current.inspect} operations=#{operations.inspect}"
          begin
            rebased = rebase(base, operations, intervening, current)
          rescue described_class::Conflict
            outcomes[:conflict] += 1
            next
          end

          result = apply(current, rebased)[:content]
          expected = expected_tokens(current_tokens, targets)
          expect(expected).not_to be_nil, "rebased although a target was not intact; #{details}"
          expect(result).to eq(expected.map(&:first).join), details
          # Later intervening edits may cut into earlier ones; whatever
          # intervening text is in the current content has to survive.
          markers.select { |marker| current.include?(marker) }.each { |marker| expect(result).to include(marker), details }
          outcomes[:rebased] += 1
        end

        # Both outcomes have to be common for the cases to mean anything.
        expect(outcomes[:rebased]).to be > 150
        expect(outcomes[:conflict]).to be > 50
      end
    end
  end
end
