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
end
