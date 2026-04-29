require "rails_helper"

RSpec.describe CoPlan::Plans::DiffToOperations do
  # Property: applying the produced ops to old_content via ApplyOperations
  # MUST yield new_content exactly. This is the hard invariant the diffing
  # logic exists to satisfy.
  def assert_roundtrip(old_content, new_content)
    ops = described_class.call(old_content: old_content, new_content: new_content)
    result = CoPlan::Plans::ApplyOperations.call(content: old_content, operations: ops)
    expect(result[:content]).to eq(new_content), -> {
      "Roundtrip failed.\nOld:\n#{old_content.inspect}\nNew:\n#{new_content.inspect}\n" \
      "Got:\n#{result[:content].inspect}\nOps:\n#{ops.inspect}"
    }
    [ops, result]
  end

  describe "no-op cases" do
    it "returns [] when content is identical" do
      expect(described_class.call(old_content: "abc", new_content: "abc")).to eq([])
    end

    it "returns [] when both contents are empty" do
      expect(described_class.call(old_content: "", new_content: "")).to eq([])
    end

    it "handles nil inputs as empty" do
      expect(described_class.call(old_content: nil, new_content: nil)).to eq([])
    end
  end

  describe "single hunk" do
    it "produces one op when a single line is changed in the middle" do
      old = "alpha\nbeta\ngamma\n"
      new = "alpha\nBETA\ngamma\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["op"]).to eq("replace_exact")
      expect(ops[0]["old_text"]).to eq("beta\n")
      expect(ops[0]["new_text"]).to eq("BETA\n")
      expect(ops[0]["_pre_resolved_ranges"]).to eq([[6, 11]])
    end

    it "produces one op for an append at end of file" do
      old = "line one\nline two\n"
      new = "line one\nline two\nline three\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("")
      expect(ops[0]["new_text"]).to eq("line three\n")
      expect(ops[0]["_pre_resolved_ranges"]).to eq([[old.length, old.length]])
    end

    it "produces one op for an insert at start of file" do
      old = "line two\nline three\n"
      new = "line one\nline two\nline three\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("")
      expect(ops[0]["new_text"]).to eq("line one\n")
      expect(ops[0]["_pre_resolved_ranges"]).to eq([[0, 0]])
    end

    it "produces one op for an insert in the middle" do
      old = "alpha\ngamma\n"
      new = "alpha\nbeta\ngamma\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("")
      expect(ops[0]["new_text"]).to eq("beta\n")
      expect(ops[0]["_pre_resolved_ranges"]).to eq([[6, 6]])
    end

    it "produces one op for a deletion in the middle" do
      old = "alpha\nbeta\ngamma\n"
      new = "alpha\ngamma\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("beta\n")
      expect(ops[0]["new_text"]).to eq("")
      expect(ops[0]["_pre_resolved_ranges"]).to eq([[6, 11]])
    end

    it "produces one op for a deletion at end of file" do
      old = "a\nb\nc\n"
      new = "a\nb\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("c\n")
      expect(ops[0]["new_text"]).to eq("")
    end

    it "produces one op for a deletion at start of file" do
      old = "a\nb\nc\n"
      new = "b\nc\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("a\n")
      expect(ops[0]["new_text"]).to eq("")
      expect(ops[0]["_pre_resolved_ranges"]).to eq([[0, 2]])
    end

    it "groups multiple consecutive changed lines into one hunk" do
      old = "header\na\nb\nc\nfooter\n"
      new = "header\nA\nB\nC\nfooter\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("a\nb\nc\n")
      expect(ops[0]["new_text"]).to eq("A\nB\nC\n")
    end

    it "groups a delete + insert pair into one hunk when they're contiguous" do
      old = "header\nold1\nold2\nfooter\n"
      new = "header\nnew1\nnew2\nnew3\nfooter\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
    end
  end

  describe "multiple disjoint hunks" do
    it "produces independent ops for non-adjacent changes" do
      old = "a\nb\nc\nd\ne\nf\ng\n"
      new = "a\nB\nc\nd\nE\nf\ng\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(2)
      expect(ops[0]["old_text"]).to eq("b\n")
      expect(ops[0]["new_text"]).to eq("B\n")
      expect(ops[1]["old_text"]).to eq("e\n")
      expect(ops[1]["new_text"]).to eq("E\n")
    end

    it "shifts later ops' ranges to account for prior ops' delta growth" do
      old = "a\nb\nc\n"
      new = "AAAAAA\nb\nC\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(2)
      # First op replaces "a\n" (positions 0..2) with "AAAAAA\n" (delta = +5)
      expect(ops[0]["_pre_resolved_ranges"]).to eq([[0, 2]])
      # Second op replaces "c\n" — originally at positions 4..6 in old,
      # but after op 1 those positions are at 9..11 in the working content.
      expect(ops[1]["_pre_resolved_ranges"]).to eq([[9, 11]])
    end

    it "shifts later ops' ranges to account for prior ops' delta shrinkage" do
      old = "aaaaaa\nb\nc\n"
      new = "X\nb\nC\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(2)
      expect(ops[0]["_pre_resolved_ranges"]).to eq([[0, 7]])
      # Original "c\n" was at positions 9..11; after op 1 (delta = -5) they're at 4..6.
      expect(ops[1]["_pre_resolved_ranges"]).to eq([[4, 6]])
    end

    it "handles insert + change + delete in one document" do
      old = "header\nkeep1\nold_change\nkeep2\nold_delete\nfooter\n"
      new = "INSERTED\nheader\nkeep1\nnew_change\nkeep2\nfooter\n"
      assert_roundtrip(old, new)
    end
  end

  describe "edge cases" do
    it "works when old is empty" do
      ops, _ = assert_roundtrip("", "alpha\nbeta\n")
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("")
      expect(ops[0]["new_text"]).to eq("alpha\nbeta\n")
    end

    it "works when new is empty" do
      ops, _ = assert_roundtrip("alpha\nbeta\n", "")
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("alpha\nbeta\n")
      expect(ops[0]["new_text"]).to eq("")
    end

    it "preserves trailing-newline absence in old" do
      old = "a\nb"  # no trailing newline
      new = "a\nB"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("b")
      expect(ops[0]["new_text"]).to eq("B")
    end

    it "preserves trailing-newline addition" do
      assert_roundtrip("a\nb", "a\nb\n")
    end

    it "preserves trailing-newline removal" do
      assert_roundtrip("a\nb\n", "a\nb")
    end

    it "handles unicode content correctly (positions are character-based)" do
      old = "café\n☕ coffee\nend\n"
      new = "café\n☕ tea\nend\n"
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to eq("☕ coffee\n")
      expect(ops[0]["new_text"]).to eq("☕ tea\n")
    end

    it "handles a fully replaced single-line file" do
      ops, _ = assert_roundtrip("hello", "world")
      expect(ops.length).to eq(1)
    end

    it "handles realistic markdown rewrite of a section" do
      old = <<~MD
        # Plan

        ## Goals

        We should use unit tests.

        ## Timeline

        Q1 2026 delivery.
      MD
      new = <<~MD
        # Plan

        ## Goals

        We should use integration tests with full coverage.
        Add CI gating on the coverage threshold.

        ## Timeline

        Q1 2026 delivery.
      MD
      ops, _ = assert_roundtrip(old, new)
      # The Goals body changed; everything else is unchanged → one hunk
      expect(ops.length).to eq(1)
      expect(ops[0]["old_text"]).to include("unit tests")
      expect(ops[0]["new_text"]).to include("integration tests with full coverage")
      expect(ops[0]["new_text"]).to include("CI gating")
    end
  end

  describe "operations metadata after applying via ApplyOperations" do
    it "produces resolved_range / new_range / delta on the applied output" do
      old = "alpha\nbeta\ngamma\n"
      new = "alpha\nBETA\ngamma\n"
      ops, result = assert_roundtrip(old, new)
      applied = result[:applied]
      expect(applied.length).to eq(1)
      expect(applied[0]["resolved_range"]).to eq([6, 11])
      expect(applied[0]["new_range"]).to eq([6, 11])
      expect(applied[0]["delta"]).to eq(0)
    end

    it "produces correct positional metadata across multiple ops" do
      old = "a\nb\nc\n"
      new = "AAAAAA\nb\nC\n"
      _, result = assert_roundtrip(old, new)
      applied = result[:applied]
      expect(applied.length).to eq(2)
      expect(applied[0]["resolved_range"]).to eq([0, 2])
      expect(applied[0]["new_range"]).to eq([0, 7])
      expect(applied[0]["delta"]).to eq(5)
      expect(applied[1]["resolved_range"]).to eq([9, 11])
      expect(applied[1]["new_range"]).to eq([9, 11])
      expect(applied[1]["delta"]).to eq(0)
    end
  end

  describe "OT compatibility (anchor preservation through generated ops)" do
    # The whole point of fine-grained hunks is that anchors in unchanged
    # regions can be transformed forward by Plans::TransformRange.
    it "lets an anchor before all changes survive unchanged" do
      old = "alpha beta gamma\nMIDDLE\nepsilon zeta\n"
      new = "alpha beta gamma\nMIDDLE_CHANGED\nepsilon zeta\n"
      ops, _ = assert_roundtrip(old, new)

      # Anchor on "alpha" at [0, 5] — unchanged, should survive
      version = double(operations_json: CoPlan::Plans::ApplyOperations.call(content: old, operations: ops)[:applied])
      transformed = CoPlan::Plans::TransformRange.transform_through_versions([0, 5], [version])
      expect(transformed).to eq([0, 5])
    end

    it "shifts an anchor after the change by the delta" do
      old = "a\nb\nc\n"  # 6 chars
      new = "AAAAAA\nb\nc\n"  # 11 chars
      ops, _ = assert_roundtrip(old, new)

      # Anchor on "c" at [4, 5] in old — should shift +5 to [9, 10] in new
      applied = CoPlan::Plans::ApplyOperations.call(content: old, operations: ops)[:applied]
      version = double(operations_json: applied)
      transformed = CoPlan::Plans::TransformRange.transform_through_versions([4, 5], [version])
      expect(transformed).to eq([9, 10])
    end

    it "marks an anchor inside the changed region as conflicting" do
      old = "a\nbeta\nc\n"
      new = "a\nGAMMA\nc\n"
      ops, _ = assert_roundtrip(old, new)

      # Anchor on "beta" at [2, 6] — overlaps the changed range, must conflict
      applied = CoPlan::Plans::ApplyOperations.call(content: old, operations: ops)[:applied]
      version = double(operations_json: applied)
      expect {
        CoPlan::Plans::TransformRange.transform_through_versions([2, 6], [version])
      }.to raise_error(CoPlan::Plans::TransformRange::Conflict)
    end
  end

  describe "tricky LCS alignments" do
    # When old has repeated identical lines, LCS has multiple valid alignments;
    # whichever it picks, the produced ops MUST roundtrip exactly.
    it "roundtrips when old has many repeated identical lines (insertion)" do
      old = "x\nx\nx\nx\nx\n"
      new = "x\nx\nNEW\nx\nx\nx\n"
      assert_roundtrip(old, new)
    end

    it "roundtrips when old has many repeated identical lines (deletion)" do
      old = "x\nx\nx\nx\nx\n"
      new = "x\nx\nx\nx\n"
      assert_roundtrip(old, new)
    end

    it "roundtrips when lines share a long common prefix" do
      old = "prefix_one\nprefix_two\nprefix_three\n"
      new = "prefix_one\nprefix_TWO_changed\nprefix_three\n"
      assert_roundtrip(old, new)
    end

    it "roundtrips when lines share a common suffix" do
      old = "alpha_end\nbeta_end\ngamma_end\n"
      new = "alpha_end\nBETA_end\ngamma_end\n"
      assert_roundtrip(old, new)
    end

    it "roundtrips a contiguous delete-then-insert at the same position" do
      old = "header\nold_a\nold_b\nfooter\n"
      new = "header\nfooter\nnew_a\nnew_b\n"
      assert_roundtrip(old, new)
    end

    it "handles mixed delete + change + insert in one hunk" do
      old = "h\nremove1\nremove2\nchange_me\nfooter\n"
      new = "h\nchanged\ninsert1\ninsert2\nfooter\n"
      assert_roundtrip(old, new)
    end

    it "roundtrips when many small disjoint hunks span a large file" do
      old_lines = Array.new(50) { |i| "line_#{i}\n" }
      new_lines = old_lines.dup
      [3, 11, 27, 41].each { |i| new_lines[i] = "CHANGED_#{i}\n" }
      assert_roundtrip(old_lines.join, new_lines.join)
    end
  end

  describe "very long single-line content" do
    it "roundtrips a 100k-character single line" do
      old = "x" * 100_000
      new = "y" * 100_000
      ops, _ = assert_roundtrip(old, new)
      expect(ops.length).to eq(1)
    end

    it "roundtrips a long paragraph with mid-line word change" do
      paragraph = "word " * 5_000  # 25k chars, single line
      old = paragraph
      new = paragraph.sub("word ", "WORD ")
      # No newlines: this is one logical line, so the entire paragraph
      # diffs as a single replacement. That's fine — we just need exactness.
      assert_roundtrip(old, new)
    end
  end

  describe "stress: random rewrites roundtrip" do
    # Small fuzz check: random line-level edits must always roundtrip.
    it "roundtrips for many random old/new pairs" do
      srand(42) # deterministic
      30.times do
        old_lines = Array.new(rand(0..15)) { "line_#{rand(1000)}\n" }
        new_lines = old_lines.dup

        # Apply a few random mutations
        rand(0..5).times do
          op = %i[insert delete change].sample
          case op
          when :insert
            idx = rand(0..new_lines.length)
            new_lines.insert(idx, "ins_#{rand(1000)}\n")
          when :delete
            next if new_lines.empty?
            new_lines.delete_at(rand(new_lines.length))
          when :change
            next if new_lines.empty?
            new_lines[rand(new_lines.length)] = "chg_#{rand(1000)}\n"
          end
        end

        assert_roundtrip(old_lines.join, new_lines.join)
      end
    end
  end
end
