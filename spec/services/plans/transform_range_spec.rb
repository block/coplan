require "rails_helper"

RSpec.describe Plans::TransformRange do
  describe ".transform" do
    describe "basic transform" do
      it "shifts range when edit is entirely before" do
        # Edit at [0, 5] replaces 5 chars with 8 chars (delta +3)
        range = [10, 20]
        edit = { "resolved_range" => [0, 5], "delta" => 3 }
        expect(described_class.transform(range, edit)).to eq([13, 23])
      end

      it "leaves range unchanged when edit is entirely after" do
        range = [10, 20]
        edit = { "resolved_range" => [25, 30], "delta" => 5 }
        expect(described_class.transform(range, edit)).to eq([10, 20])
      end

      it "shifts range when edit ends where range starts (e2 == s)" do
        range = [10, 20]
        edit = { "resolved_range" => [5, 10], "delta" => 3 }
        expect(described_class.transform(range, edit)).to eq([13, 23])
      end

      it "leaves range unchanged when edit starts where range ends (s2 == e)" do
        range = [10, 20]
        edit = { "resolved_range" => [20, 25], "delta" => 3 }
        expect(described_class.transform(range, edit)).to eq([10, 20])
      end

      it "raises Conflict when ranges overlap" do
        range = [10, 20]
        edit = { "resolved_range" => [15, 25], "delta" => 3 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end

      it "raises Conflict when edit contains our range" do
        range = [10, 20]
        edit = { "resolved_range" => [5, 25], "delta" => -5 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end

      it "raises Conflict when our range contains edit" do
        range = [10, 20]
        edit = { "resolved_range" => [12, 18], "delta" => 2 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end

      it "raises Conflict on partial overlap from left" do
        range = [10, 20]
        edit = { "resolved_range" => [5, 15], "delta" => 1 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end

      it "raises Conflict on partial overlap from right" do
        range = [10, 20]
        edit = { "resolved_range" => [15, 25], "delta" => 1 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end
    end

    describe "delta calculations" do
      it "handles positive delta (replacement longer than original)" do
        range = [20, 30]
        edit = { "resolved_range" => [5, 10], "delta" => 7 }
        expect(described_class.transform(range, edit)).to eq([27, 37])
      end

      it "handles negative delta (replacement shorter)" do
        range = [20, 30]
        edit = { "resolved_range" => [5, 10], "delta" => -3 }
        expect(described_class.transform(range, edit)).to eq([17, 27])
      end

      it "handles zero delta (same length replacement) without overlap" do
        range = [20, 30]
        edit = { "resolved_range" => [5, 10], "delta" => 0 }
        expect(described_class.transform(range, edit)).to eq([20, 30])
      end

      it "detects overlap even with zero delta" do
        range = [10, 20]
        edit = { "resolved_range" => [15, 18], "delta" => 0 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end

      it "handles large positive delta" do
        range = [100, 200]
        edit = { "resolved_range" => [0, 10], "delta" => 5000 }
        expect(described_class.transform(range, edit)).to eq([5100, 5200])
      end

      it "handles large negative delta" do
        range = [100, 200]
        edit = { "resolved_range" => [0, 50], "delta" => -45 }
        expect(described_class.transform(range, edit)).to eq([55, 155])
      end

      it "derives delta from new_range" do
        range = [20, 30]
        # Edit replaced [5, 10] (5 chars) with new range [5, 12] (7 chars), delta = +2
        edit = { "resolved_range" => [5, 10], "new_range" => [5, 12] }
        expect(described_class.transform(range, edit)).to eq([22, 32])
      end

      it "raises ArgumentError when neither delta nor new_range provided" do
        range = [10, 20]
        edit = { "resolved_range" => [0, 5] }
        expect { described_class.transform(range, edit) }.to raise_error(ArgumentError, /must contain/)
      end
    end

    describe "zero-width ranges (insert points)" do
      it "shifts insert point when edit is before" do
        range = [10, 10]
        edit = { "resolved_range" => [0, 5], "delta" => 3 }
        expect(described_class.transform(range, edit)).to eq([13, 13])
      end

      it "leaves insert point unchanged when edit is after" do
        range = [10, 10]
        edit = { "resolved_range" => [15, 20], "delta" => 5 }
        expect(described_class.transform(range, edit)).to eq([10, 10])
      end

      it "shifts insert point when edit ends at insert point (e2 == s)" do
        range = [10, 10]
        edit = { "resolved_range" => [5, 10], "delta" => 3 }
        expect(described_class.transform(range, edit)).to eq([13, 13])
      end

      it "raises Conflict when insert point is inside edit range" do
        range = [10, 10]
        edit = { "resolved_range" => [5, 15], "delta" => 3 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end

      it "raises Conflict when insert point is at edit start" do
        range = [10, 10]
        edit = { "resolved_range" => [10, 15], "delta" => 3 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end
    end

    describe "symbol keys" do
      it "works with symbol keys in edit_data" do
        range = [10, 20]
        edit = { resolved_range: [0, 5], delta: 3 }
        expect(described_class.transform(range, edit)).to eq([13, 23])
      end
    end

    describe "edge cases" do
      it "transforms range at document start [0, N] correctly" do
        range = [0, 10]
        edit = { "resolved_range" => [20, 25], "delta" => 5 }
        expect(described_class.transform(range, edit)).to eq([0, 10])
      end

      it "transforms range at document start when edit is also at start" do
        range = [0, 10]
        edit = { "resolved_range" => [0, 5], "delta" => 3 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end

      it "transforms range at document end correctly" do
        range = [990, 1000]
        edit = { "resolved_range" => [0, 10], "delta" => 5 }
        expect(described_class.transform(range, edit)).to eq([995, 1005])
      end

      it "raises Conflict for empty edit (delta=0) overlapping range" do
        range = [10, 20]
        edit = { "resolved_range" => [12, 12], "delta" => 0 }
        expect { described_class.transform(range, edit) }.to raise_error(described_class::Conflict)
      end
    end
  end

  describe ".transform_through_versions" do
    it "transforms through two non-overlapping versions" do
      versions = [
        { operations_json: [{ "resolved_range" => [0, 5], "delta" => 3 }] },
        { operations_json: [{ "resolved_range" => [0, 3], "delta" => 2 }] }
      ]
      # Start: [20, 30]
      # After v1: edit [0,5] delta +3 → [23, 33]
      # After v2: edit [0,3] delta +2 → [25, 35]
      expect(described_class.transform_through_versions([20, 30], versions)).to eq([25, 35])
    end

    it "transforms through five intervening versions" do
      versions = (1..5).map do |i|
        { operations_json: [{ "resolved_range" => [0, 1], "delta" => 1 }] }
      end
      # Each version adds 1 to both s and e, 5 total
      expect(described_class.transform_through_versions([50, 60], versions)).to eq([55, 65])
    end

    it "transforms through ten intervening versions" do
      versions = (1..10).map do |i|
        { operations_json: [{ "resolved_range" => [0, 2], "delta" => 3 }] }
      end
      # Each version shifts by +3, 10 total = +30
      expect(described_class.transform_through_versions([100, 200], versions)).to eq([130, 230])
    end

    it "skips version with empty operations_json" do
      versions = [
        { operations_json: [{ "resolved_range" => [0, 5], "delta" => 3 }] },
        { operations_json: [] },
        { operations_json: nil },
        { operations_json: [{ "resolved_range" => [0, 3], "delta" => 2 }] }
      ]
      expect(described_class.transform_through_versions([20, 30], versions)).to eq([25, 35])
    end

    it "transforms through version with replace_all (multiple replacements)" do
      versions = [
        {
          operations_json: [
            {
              "replacements" => [
                { "resolved_range" => [0, 3], "delta" => 2 },
                { "resolved_range" => [50, 53], "delta" => 2 }
              ]
            }
          ]
        }
      ]
      # Range [100, 110] is after both replacements
      # Replacements processed in reverse order: [50,53] delta +2 → [102, 112], then [0,3] delta +2 → [104, 114]
      expect(described_class.transform_through_versions([100, 110], versions)).to eq([104, 114])
    end

    it "handles replace_all where range is between replacements" do
      versions = [
        {
          operations_json: [
            {
              "replacements" => [
                { "resolved_range" => [0, 3], "delta" => 2 },
                { "resolved_range" => [200, 203], "delta" => 5 }
              ]
            }
          ]
        }
      ]
      # Range [100, 110]
      # Reversed: [200,203] first — range is before, no shift → [100, 110]
      # Then [0,3] — range is after, shift by +2 → [102, 112]
      expect(described_class.transform_through_versions([100, 110], versions)).to eq([102, 112])
    end

    it "works with PlanVersion-like objects" do
      version = double("PlanVersion", operations_json: [{ "resolved_range" => [0, 5], "delta" => 3 }])
      expect(described_class.transform_through_versions([20, 30], [version])).to eq([23, 33])
    end

    it "works with string-keyed hashes" do
      versions = [
        { "operations_json" => [{ "resolved_range" => [0, 5], "delta" => 3 }] }
      ]
      expect(described_class.transform_through_versions([20, 30], versions)).to eq([23, 33])
    end

    it "raises Conflict when a version's edit overlaps the range" do
      versions = [
        { operations_json: [{ "resolved_range" => [15, 25], "delta" => 3 }] }
      ]
      expect { described_class.transform_through_versions([10, 20], versions) }.to raise_error(described_class::Conflict)
    end
  end

  describe "commutativity property" do
    it "produces the same result for non-overlapping edits regardless of order" do
      edit_a = { "resolved_range" => [0, 5], "delta" => 3 }
      edit_b = { "resolved_range" => [50, 55], "delta" => -2 }

      range = [60, 70]

      # Apply A then B
      r1 = described_class.transform(range, edit_a)
      # After A: edit_b's position needs adjusting for testing commutativity,
      # but since both are before range and non-overlapping with each other,
      # the total shift should be the same
      r1 = described_class.transform(r1, { "resolved_range" => [53, 58], "delta" => -2 })

      # Apply B then A
      r2 = described_class.transform(range, edit_b)
      r2 = described_class.transform(r2, { "resolved_range" => [0, 5], "delta" => 3 })

      expect(r1).to eq(r2)
    end

    it "produces the same result for two edits both before the range" do
      edit_a_data = { "resolved_range" => [0, 10], "delta" => 5 }
      edit_b_data = { "resolved_range" => [20, 30], "delta" => -3 }

      range = [50, 60]

      # Order 1: A then B (B shifts by A's delta)
      r1 = described_class.transform(range, edit_a_data)
      r1 = described_class.transform(r1, { "resolved_range" => [25, 35], "delta" => -3 })

      # Order 2: B then A (A position unchanged since it's before B)
      r2 = described_class.transform(range, edit_b_data)
      r2 = described_class.transform(r2, { "resolved_range" => [0, 10], "delta" => 5 })

      expect(r1).to eq(r2)
    end
  end
end
