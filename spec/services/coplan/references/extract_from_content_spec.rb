require "rails_helper"

RSpec.describe CoPlan::References::ExtractFromContent do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }

  def update_content(plan, content)
    version = plan.current_plan_version
    version.update!(content_markdown: content)
  end

  describe ".call" do
    it "extracts markdown links from content" do
      update_content(plan, "Check out [Rails](https://rubyonrails.org) for details.")
      described_class.call(plan: plan)

      expect(plan.references.count).to eq(1)
      ref = plan.references.first
      expect(ref.url).to eq("https://rubyonrails.org")
      expect(ref.title).to eq("Rails")
      expect(ref.reference_type).to eq("link")
      expect(ref.source).to eq("extracted")
    end

    it "classifies GitHub repo URLs" do
      update_content(plan, "See [repo](https://github.com/org/my-repo) for code.")
      described_class.call(plan: plan)

      ref = plan.references.first
      expect(ref.reference_type).to eq("repository")
    end

    it "classifies GitHub PR URLs" do
      update_content(plan, "See [PR](https://github.com/org/repo/pull/123) for changes.")
      described_class.call(plan: plan)

      ref = plan.references.first
      expect(ref.reference_type).to eq("pull_request")
    end

    it "classifies Google Docs URLs" do
      update_content(plan, "See [doc](https://docs.google.com/document/d/abc123) for details.")
      described_class.call(plan: plan)

      ref = plan.references.first
      expect(ref.reference_type).to eq("document")
    end

    it "removes extracted references when links are removed from content" do
      update_content(plan, "See [Rails](https://rubyonrails.org) and [Ruby](https://ruby-lang.org).")
      described_class.call(plan: plan)
      expect(plan.references.count).to eq(2)

      update_content(plan, "See [Rails](https://rubyonrails.org) only.")
      described_class.call(plan: plan)
      expect(plan.references.count).to eq(1)
      expect(plan.references.first.url).to eq("https://rubyonrails.org")
    end

    it "does not remove explicit references" do
      create(:reference, plan: plan, url: "https://example.com", source: "explicit")
      update_content(plan, "No links here.")
      described_class.call(plan: plan)

      refs = plan.references.reload
      expect(refs.count).to eq(1)
      expect(refs.first.source).to eq("explicit")
    end

    it "does not overwrite explicit references with extracted ones" do
      create(:reference, plan: plan, url: "https://rubyonrails.org", source: "explicit", title: "My Title")
      update_content(plan, "See [Rails](https://rubyonrails.org).")
      described_class.call(plan: plan)

      ref = plan.references.find_by(url: "https://rubyonrails.org")
      expect(ref.source).to eq("explicit")
      expect(ref.title).to eq("My Title")
    end

    it "is idempotent" do
      update_content(plan, "See [Rails](https://rubyonrails.org).")
      described_class.call(plan: plan)
      described_class.call(plan: plan)

      expect(plan.references.count).to eq(1)
    end

    it "handles empty content" do
      plan.current_plan_version.update_column(:content_markdown, "")
      described_class.call(plan: plan)
      expect(plan.references.count).to eq(0)
    end

    it "sets target_plan_id for plan references" do
      target_plan = create(:plan, created_by_user: user)
      update_content(plan, "See [other plan](https://coplan.example.com/plans/#{target_plan.id}).")
      described_class.call(plan: plan)

      ref = plan.references.first
      expect(ref.reference_type).to eq("plan")
      expect(ref.target_plan_id).to eq(target_plan.id)
    end

    it "does not set target_plan_id for self-references" do
      update_content(plan, "See [this plan](https://coplan.example.com/plans/#{plan.id}).")
      described_class.call(plan: plan)

      ref = plan.references.first
      expect(ref.target_plan_id).to be_nil
    end

    it "extracts bare URLs" do
      update_content(plan, "Visit https://example.com for more info.")
      described_class.call(plan: plan)

      expect(plan.references.count).to eq(1)
      expect(plan.references.first.url).to eq("https://example.com")
    end
  end
end
