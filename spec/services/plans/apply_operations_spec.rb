require "rails_helper"

RSpec.describe Plans::ApplyOperations do
  describe "replace_exact" do
    it "replaces text" do
      result = Plans::ApplyOperations.call(
        content: "Hello world, hello universe.",
        operations: [{ "op" => "replace_exact", "old_text" => "world", "new_text" => "planet", "count" => 1 }]
      )
      expect(result[:content]).to eq("Hello planet, hello universe.")
      expect(result[:applied].length).to eq(1)
    end

    it "replaces all occurrences with count 2" do
      result = Plans::ApplyOperations.call(
        content: "foo bar foo baz",
        operations: [{ "op" => "replace_exact", "old_text" => "foo", "new_text" => "qux", "count" => 2 }]
      )
      expect(result[:content]).to eq("qux bar qux baz")
    end

    it "fails when text not found" do
      expect {
        Plans::ApplyOperations.call(
          content: "Hello world",
          operations: [{ "op" => "replace_exact", "old_text" => "missing", "new_text" => "found", "count" => 1 }]
        )
      }.to raise_error(Plans::OperationError, /found 0 occurrences/)
    end

    it "fails when too many occurrences" do
      expect {
        Plans::ApplyOperations.call(
          content: "foo foo foo",
          operations: [{ "op" => "replace_exact", "old_text" => "foo", "new_text" => "bar", "count" => 1 }]
        )
      }.to raise_error(Plans::OperationError, /found 3 occurrences/)
    end

    it "requires old_text" do
      expect {
        Plans::ApplyOperations.call(
          content: "Hello",
          operations: [{ "op" => "replace_exact", "new_text" => "Bye" }]
        )
      }.to raise_error(Plans::OperationError, /requires 'old_text'/)
    end
  end

  describe "insert_under_heading" do
    it "inserts content under heading" do
      content = "# Title\n\nIntro\n\n## Goals\n\nExisting goals."
      result = Plans::ApplyOperations.call(
        content: content,
        operations: [{ "op" => "insert_under_heading", "heading" => "## Goals", "content" => "- New goal" }]
      )
      expect(result[:content]).to include("## Goals\n\n- New goal")
      expect(result[:content]).to include("Existing goals.")
    end

    it "fails when heading not found" do
      expect {
        Plans::ApplyOperations.call(
          content: "# Title\n\nContent",
          operations: [{ "op" => "insert_under_heading", "heading" => "## Missing", "content" => "stuff" }]
        )
      }.to raise_error(Plans::OperationError, /no heading matching/)
    end

    it "fails when heading is ambiguous" do
      content = "## Goals\n\nFirst\n\n## Goals\n\nSecond"
      expect {
        Plans::ApplyOperations.call(
          content: content,
          operations: [{ "op" => "insert_under_heading", "heading" => "## Goals", "content" => "stuff" }]
        )
      }.to raise_error(Plans::OperationError, /found 2 headings/)
    end
  end

  describe "delete_paragraph_containing" do
    it "removes paragraph" do
      content = "First paragraph.\n\nThis is deprecated.\n\nThird paragraph."
      result = Plans::ApplyOperations.call(
        content: content,
        operations: [{ "op" => "delete_paragraph_containing", "needle" => "deprecated" }]
      )
      expect(result[:content]).to eq("First paragraph.\n\nThird paragraph.")
      expect(result[:content]).not_to include("deprecated")
    end

    it "fails when not found" do
      expect {
        Plans::ApplyOperations.call(
          content: "Some content.",
          operations: [{ "op" => "delete_paragraph_containing", "needle" => "missing" }]
        )
      }.to raise_error(Plans::OperationError, /no paragraph containing/)
    end

    it "fails when ambiguous" do
      content = "First deprecated thing.\n\nSecond deprecated thing."
      expect {
        Plans::ApplyOperations.call(
          content: content,
          operations: [{ "op" => "delete_paragraph_containing", "needle" => "deprecated" }]
        )
      }.to raise_error(Plans::OperationError, /found 2 paragraphs/)
    end
  end

  it "raises error for unknown operation" do
    expect {
      Plans::ApplyOperations.call(
        content: "Hello",
        operations: [{ "op" => "unknown_op" }]
      )
    }.to raise_error(Plans::OperationError, /unknown op/)
  end

  it "applies multiple operations sequentially" do
    content = "# Plan\n\n## Phase 1\n\nDo stuff.\n\n## Phase 2\n\nOld approach."
    result = Plans::ApplyOperations.call(
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
    result = Plans::ApplyOperations.call(
      content: "Hello world",
      operations: [{ "op" => "replace_exact", "old_text" => "world", "new_text" => "planet", "count" => 1 }]
    )
    expect(result[:content]).to eq("Hello planet")
  end

  it "works with symbol keys" do
    result = Plans::ApplyOperations.call(
      content: "Hello world",
      operations: [{ op: "replace_exact", old_text: "world", new_text: "planet", count: 1 }]
    )
    expect(result[:content]).to eq("Hello planet")
  end
end
