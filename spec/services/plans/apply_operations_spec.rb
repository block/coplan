require "rails_helper"

RSpec.describe CoPlan::Plans::ApplyOperations do
  describe "replace_exact" do
    it "replaces text" do
      result = CoPlan::Plans::ApplyOperations.call(
        content: "Hello world, hello universe.",
        operations: [{ "op" => "replace_exact", "old_text" => "world", "new_text" => "planet", "count" => 1 }]
      )
      expect(result[:content]).to eq("Hello planet, hello universe.")
      expect(result[:applied].length).to eq(1)
    end

    it "replaces all occurrences with count 2" do
      result = CoPlan::Plans::ApplyOperations.call(
        content: "foo bar foo baz",
        operations: [{ "op" => "replace_exact", "old_text" => "foo", "new_text" => "qux", "count" => 2 }]
      )
      expect(result[:content]).to eq("qux bar qux baz")
    end

    it "fails when text not found" do
      expect {
        CoPlan::Plans::ApplyOperations.call(
          content: "Hello world",
          operations: [{ "op" => "replace_exact", "old_text" => "missing", "new_text" => "found", "count" => 1 }]
        )
      }.to raise_error(CoPlan::Plans::OperationError, /found 0 occurrences/)
    end

    it "fails when too many occurrences" do
      expect {
        CoPlan::Plans::ApplyOperations.call(
          content: "foo foo foo",
          operations: [{ "op" => "replace_exact", "old_text" => "foo", "new_text" => "bar", "count" => 1 }]
        )
      }.to raise_error(CoPlan::Plans::OperationError, /found 3 occurrences/)
    end

    it "requires old_text" do
      expect {
        CoPlan::Plans::ApplyOperations.call(
          content: "Hello",
          operations: [{ "op" => "replace_exact", "new_text" => "Bye" }]
        )
      }.to raise_error(CoPlan::Plans::OperationError, /requires 'old_text'/)
    end
  end

  describe "insert_under_heading" do
    it "inserts content under heading" do
      content = "# Title\n\nIntro\n\n## Goals\n\nExisting goals."
      result = CoPlan::Plans::ApplyOperations.call(
        content: content,
        operations: [{ "op" => "insert_under_heading", "heading" => "## Goals", "content" => "- New goal" }]
      )
      expect(result[:content]).to include("## Goals\n- New goal")
      expect(result[:content]).to include("Existing goals.")
    end

    it "fails when heading not found" do
      expect {
        CoPlan::Plans::ApplyOperations.call(
          content: "# Title\n\nContent",
          operations: [{ "op" => "insert_under_heading", "heading" => "## Missing", "content" => "stuff" }]
        )
      }.to raise_error(CoPlan::Plans::OperationError, /no heading matching/)
    end

    it "fails when heading is ambiguous" do
      content = "## Goals\n\nFirst\n\n## Goals\n\nSecond"
      expect {
        CoPlan::Plans::ApplyOperations.call(
          content: content,
          operations: [{ "op" => "insert_under_heading", "heading" => "## Goals", "content" => "stuff" }]
        )
      }.to raise_error(CoPlan::Plans::OperationError, /found 2 headings/)
    end
  end

  describe "delete_paragraph_containing" do
    it "removes paragraph" do
      content = "First paragraph.\n\nThis is deprecated.\n\nThird paragraph."
      result = CoPlan::Plans::ApplyOperations.call(
        content: content,
        operations: [{ "op" => "delete_paragraph_containing", "needle" => "deprecated" }]
      )
      expect(result[:content]).to eq("First paragraph.\n\nThird paragraph.")
      expect(result[:content]).not_to include("deprecated")
    end

    it "fails when not found" do
      expect {
        CoPlan::Plans::ApplyOperations.call(
          content: "Some content.",
          operations: [{ "op" => "delete_paragraph_containing", "needle" => "missing" }]
        )
      }.to raise_error(CoPlan::Plans::OperationError, /no paragraph containing/)
    end

    it "fails when ambiguous" do
      content = "First deprecated thing.\n\nSecond deprecated thing."
      expect {
        CoPlan::Plans::ApplyOperations.call(
          content: content,
          operations: [{ "op" => "delete_paragraph_containing", "needle" => "deprecated" }]
        )
      }.to raise_error(CoPlan::Plans::OperationError, /found 2 paragraphs/)
    end
  end

  it "raises error for unknown operation" do
    expect {
      CoPlan::Plans::ApplyOperations.call(
        content: "Hello",
        operations: [{ "op" => "unknown_op" }]
      )
    }.to raise_error(CoPlan::Plans::OperationError, /unknown op/)
  end

  it "applies multiple operations sequentially" do
    content = "# Plan\n\n## Phase 1\n\nDo stuff.\n\n## Phase 2\n\nOld approach."
    result = CoPlan::Plans::ApplyOperations.call(
      content: content,
      operations: [
        { "op" => "replace_exact", "old_text" => "Do stuff.", "new_text" => "Do important stuff.", "count" => 1 },
        { "op" => "insert_under_heading", "heading" => "## Phase 2", "content" => "\n- New step" }
      ]
    )
    expect(result[:content]).to include("Do important stuff.")
    expect(result[:content]).to include("- New step")
    expect(result[:applied].length).to eq(2)
  end

  it "works with string keys" do
    result = CoPlan::Plans::ApplyOperations.call(
      content: "Hello world",
      operations: [{ "op" => "replace_exact", "old_text" => "world", "new_text" => "planet", "count" => 1 }]
    )
    expect(result[:content]).to eq("Hello planet")
  end

  it "works with symbol keys" do
    result = CoPlan::Plans::ApplyOperations.call(
      content: "Hello world",
      operations: [{ op: "replace_exact", old_text: "world", new_text: "planet", count: 1 }]
    )
    expect(result[:content]).to eq("Hello planet")
  end

  describe "occurrence and replace_all parameters" do
    it "occurrence: 2 targets the second match" do
      result = CoPlan::Plans::ApplyOperations.call(
        content: "foo bar foo baz foo",
        operations: [{ "op" => "replace_exact", "old_text" => "foo", "new_text" => "qux", "occurrence" => 2 }]
      )
      expect(result[:content]).to eq("foo bar qux baz foo")
    end

    it "replace_all: true replaces all occurrences" do
      result = CoPlan::Plans::ApplyOperations.call(
        content: "foo bar foo baz foo",
        operations: [{ "op" => "replace_exact", "old_text" => "foo", "new_text" => "qux", "replace_all" => true }]
      )
      expect(result[:content]).to eq("qux bar qux baz qux")
    end

    it "legacy count still works for backward compat" do
      result = CoPlan::Plans::ApplyOperations.call(
        content: "foo bar foo baz",
        operations: [{ "op" => "replace_exact", "old_text" => "foo", "new_text" => "qux", "count" => 2 }]
      )
      expect(result[:content]).to eq("qux bar qux baz")
    end
  end

  describe "resolved position data" do
    it "single replace_exact includes resolved_range, new_range, and delta" do
      result = CoPlan::Plans::ApplyOperations.call(
        content: "Hello world",
        operations: [{ "op" => "replace_exact", "old_text" => "world", "new_text" => "planet", "count" => 1 }]
      )
      applied = result[:applied][0]
      expect(applied["resolved_range"]).to eq([6, 11])
      expect(applied["new_range"]).to eq([6, 12])
      expect(applied["delta"]).to eq(1)
    end

    it "replace_all applied ops include replacements array" do
      result = CoPlan::Plans::ApplyOperations.call(
        content: "foo bar foo baz",
        operations: [{ "op" => "replace_exact", "old_text" => "foo", "new_text" => "quux", "replace_all" => true }]
      )
      applied = result[:applied][0]
      expect(applied["replacements"]).to be_an(Array)
      expect(applied["replacements"].length).to eq(2)

      first = applied["replacements"][0]
      expect(first["resolved_range"]).to eq([0, 3])
      expect(first["new_range"]).to eq([0, 4])
      expect(first["delta"]).to eq(1)

      second = applied["replacements"][1]
      expect(second["resolved_range"]).to eq([8, 11])
      expect(second["new_range"]).to eq([8, 12])
      expect(second["delta"]).to eq(1)

      expect(applied["total_delta"]).to eq(2)
    end

    it "insert_under_heading applied op includes position data" do
      content = "# Title\n\nIntro\n\n## Goals\n\nExisting goals."
      result = CoPlan::Plans::ApplyOperations.call(
        content: content,
        operations: [{ "op" => "insert_under_heading", "heading" => "## Goals", "content" => "- New goal" }]
      )
      applied = result[:applied][0]
      expect(applied["resolved_range"]).to be_an(Array)
      expect(applied["resolved_range"].length).to eq(2)
      expect(applied["new_range"]).to be_an(Array)
      expect(applied["delta"]).to be > 0
    end

    it "delete_paragraph_containing applied op includes position data" do
      content = "First paragraph.\n\nThis is deprecated.\n\nThird paragraph."
      result = CoPlan::Plans::ApplyOperations.call(
        content: content,
        operations: [{ "op" => "delete_paragraph_containing", "needle" => "deprecated" }]
      )
      applied = result[:applied][0]
      expect(applied["resolved_range"]).to be_an(Array)
      expect(applied["new_range"][0]).to eq(applied["new_range"][1])
      expect(applied["delta"]).to be < 0
    end

    it "multiple sequential operations have correct position data for each" do
      content = "Hello world. Goodbye world."
      result = CoPlan::Plans::ApplyOperations.call(
        content: content,
        operations: [
          { "op" => "replace_exact", "old_text" => "Hello", "new_text" => "Hi", "count" => 1 },
          { "op" => "replace_exact", "old_text" => "Goodbye", "new_text" => "Bye", "count" => 1 }
        ]
      )
      expect(result[:content]).to eq("Hi world. Bye world.")

      first_applied = result[:applied][0]
      expect(first_applied["resolved_range"]).to eq([0, 5])
      expect(first_applied["new_range"]).to eq([0, 2])
      expect(first_applied["delta"]).to eq(-3)

      second_applied = result[:applied][1]
      expect(second_applied["resolved_range"]).to eq([10, 17])
      expect(second_applied["new_range"]).to eq([10, 13])
      expect(second_applied["delta"]).to eq(-4)
    end
  end
end
