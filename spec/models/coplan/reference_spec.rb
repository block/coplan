require "rails_helper"

RSpec.describe CoPlan::Reference, type: :model do
  describe "validations" do
    let(:plan) { create(:plan) }

    it "requires url" do
      ref = build(:reference, plan: plan, url: nil)
      expect(ref).not_to be_valid
      expect(ref.errors[:url]).to include("can't be blank")
    end

    it "requires reference_type" do
      ref = build(:reference, plan: plan, reference_type: nil)
      expect(ref).not_to be_valid
    end

    it "requires source" do
      ref = build(:reference, plan: plan, source: nil)
      expect(ref).not_to be_valid
    end

    it "validates reference_type inclusion" do
      ref = build(:reference, plan: plan, reference_type: "invalid")
      expect(ref).not_to be_valid
    end

    it "validates source inclusion" do
      ref = build(:reference, plan: plan, source: "invalid")
      expect(ref).not_to be_valid
    end

    it "enforces uniqueness of url per plan" do
      create(:reference, plan: plan, url: "https://example.com")
      ref = build(:reference, plan: plan, url: "https://example.com")
      expect(ref).not_to be_valid
    end

    it "allows same url on different plans" do
      other_plan = create(:plan)
      create(:reference, plan: plan, url: "https://example.com")
      ref = build(:reference, plan: other_plan, url: "https://example.com")
      expect(ref).to be_valid
    end
  end

  describe ".classify_url" do
    it "classifies GitHub PR URLs" do
      expect(described_class.classify_url("https://github.com/org/repo/pull/123")).to eq("pull_request")
    end

    it "classifies GitHub repo URLs" do
      expect(described_class.classify_url("https://github.com/org/repo")).to eq("repository")
      expect(described_class.classify_url("https://github.com/org/repo/")).to eq("repository")
      expect(described_class.classify_url("https://github.com/org/repo/tree/main")).to eq("repository")
      expect(described_class.classify_url("https://github.com/org/repo/blob/main/file.rb")).to eq("repository")
    end

    it "classifies CoPlan plan URLs" do
      expect(described_class.classify_url("https://coplan.example.com/plans/019d54a7-ea13-72d5-bc54-fc44cb9b939a")).to eq("plan")
    end

    it "classifies Google Docs URLs" do
      expect(described_class.classify_url("https://docs.google.com/document/d/abc123")).to eq("document")
      expect(described_class.classify_url("https://drive.google.com/file/d/abc123")).to eq("document")
    end

    it "classifies Notion URLs" do
      expect(described_class.classify_url("https://www.notion.so/page-abc123")).to eq("document")
      expect(described_class.classify_url("https://team.notion.site/page-abc123")).to eq("document")
    end

    it "classifies Confluence URLs" do
      expect(described_class.classify_url("https://wiki.confluence.example.com/display/TEAM/Page")).to eq("document")
    end

    it "defaults to link for unknown URLs" do
      expect(described_class.classify_url("https://example.com/something")).to eq("link")
    end
  end

  describe ".extract_target_plan_id" do
    it "extracts UUID from plan URLs" do
      url = "https://coplan.example.com/plans/019d54a7-ea13-72d5-bc54-fc44cb9b939a"
      expect(described_class.extract_target_plan_id(url)).to eq("019d54a7-ea13-72d5-bc54-fc44cb9b939a")
    end

    it "returns nil for non-plan URLs" do
      expect(described_class.extract_target_plan_id("https://example.com")).to be_nil
    end
  end

  describe "scopes" do
    let(:plan) { create(:plan) }

    it ".extracted returns only extracted references" do
      extracted = create(:reference, :extracted, plan: plan, url: "https://a.com")
      create(:reference, plan: plan, url: "https://b.com", source: "explicit")

      expect(described_class.extracted).to eq([extracted])
    end

    it ".explicit returns only explicit references" do
      create(:reference, :extracted, plan: plan, url: "https://a.com")
      explicit = create(:reference, plan: plan, url: "https://b.com", source: "explicit")

      expect(described_class.explicit).to eq([explicit])
    end
  end
end
