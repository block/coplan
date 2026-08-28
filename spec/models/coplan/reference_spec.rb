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

    it "enforces database uniqueness when a writer omits the generated digest" do
      create(:reference, plan: plan, url: "https://example.com")
      attributes = {
        id: SecureRandom.uuid,
        plan_id: plan.id,
        url: "https://example.com",
        reference_type: "link",
        source: "extracted",
        created_at: Time.current,
        updated_at: Time.current
      }

      expect { described_class.insert_all!([ attributes ]) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "stores URLs longer than a database string" do
      url = "https://example.com/?query=#{"x" * 500}"
      ref = create(:reference, plan: plan, url: url)

      expect(ref.reload.url).to eq(url)
      expect(ref.url_digest).to eq(Digest::SHA256.hexdigest(url))
    end

    it "updates the database-generated digest when the URL changes" do
      ref = create(:reference, plan: plan, url: "https://example.com/old")

      ref.update!(url: "https://example.com/new")

      expect(ref.reload.url_digest).to eq(Digest::SHA256.hexdigest(ref.url))
    end

    it "allows same url on different plans" do
      other_plan = create(:plan)
      create(:reference, plan: plan, url: "https://example.com")
      ref = build(:reference, plan: other_plan, url: "https://example.com")
      expect(ref).to be_valid
    end

    it "treats case-sensitive URL paths as distinct" do
      create(:reference, plan: plan, url: "https://example.com/Report")

      expect {
        create(:reference, plan: plan, url: "https://example.com/report")
      }.to change(described_class, :count).by(1)
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

    # The readable form is what anyone copies out of the address bar now, so
    # it has to read as a plan link — but only once we know it's ours.
    # /hampton/cart-roadmap is shaped like any other site's URL, so the host
    # is the whole distinction, and callers who know it pass it in.
    it "classifies readable CoPlan document URLs on our own host" do
      host = "coplan.example.com"
      expect(described_class.classify_url("https://coplan.example.com/hampton/cart-roadmap", own_host: host)).to eq("plan")
      expect(described_class.classify_url("https://coplan.example.com/hampton/liveorder/q3/cart-roadmap", own_host: host)).to eq("plan")
    end

    # The reason the host check isn't optional: without it, every link with
    # two path segments would file itself as one of our documents.
    it "does not claim someone else's two-segment URL" do
      expect(described_class.classify_url("https://wiki.example.com/team/onboarding", own_host: "coplan.example.com")).to eq("link")
      expect(described_class.classify_url("https://coplan.example.com/hampton/cart-roadmap")).to eq("link")
    end

    # A bare library or a workspace path isn't a document.
    it "does not classify a library root as a plan" do
      expect(described_class.classify_url("https://coplan.example.com/hampton", own_host: "coplan.example.com")).to eq("link")
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

    context "readable document URLs" do
      let(:author) { create(:coplan_user, username: "hampton") }
      let(:folder) { create(:folder, name: "LiveOrder", created_by_user: author) }
      let!(:plan) do
        create(:plan, :published, created_by_user: author, title: "Cart Roadmap").tap do |p|
          CoPlan::Plans::Place.call(plan: p, folder: folder, actor: author)
        end
      end

      it "resolves the path to the document it names" do
        expect(described_class.extract_target_plan_id("https://coplan.example.com/hampton/liveorder/cart-roadmap"))
          .to eq(plan.id)
      end

      # An inline link written before a rename still points at the same
      # document, so it should still name it — the alias walk is the same
      # one that makes following the link work.
      it "follows a rename through the alias table" do
        plan.reload.update!(title: "Basket Roadmap")
        expect(plan.reload.url_path).to eq("hampton/liveorder/basket-roadmap")

        expect(described_class.extract_target_plan_id("https://coplan.example.com/hampton/liveorder/cart-roadmap"))
          .to eq(plan.id)
      end

      it "returns nil for a path that names nothing" do
        expect(described_class.extract_target_plan_id("https://coplan.example.com/hampton/nope/gone")).to be_nil
      end

      # No host needed here: resolving IS the is-this-ours test, and it's the
      # stronger one. An external URL whose first segment isn't a handle we
      # have never reaches the segment walk.
      it "leaves an unrelated site's URL alone" do
        expect(described_class.extract_target_plan_id("https://wiki.example.com/team/onboarding")).to be_nil
      end
    end
  end

  describe ".resolve_link" do
    let(:author) { create(:coplan_user, username: "hampton") }
    let!(:plan) { create(:plan, :published, created_by_user: author, title: "Cart Roadmap") }

    # Type and target are one question for a readable address: a path that
    # resolves to one of our documents is a plan reference, so a URL that
    # classified as a plain "link" gets promoted when it lands.
    it "promotes a resolvable readable link to a plan reference" do
      expect(described_class.resolve_link("https://coplan.example.com/hampton/cart-roadmap"))
        .to eq([ "plan", plan.id ])
    end

    it "leaves an unresolvable link a link" do
      expect(described_class.resolve_link("https://wiki.example.com/team/onboarding"))
        .to eq([ "link", nil ])
    end

    # A document linking to itself is a link, not a reference to another one.
    it "drops the citing plan's own address" do
      type, target = described_class.resolve_link(
        "https://coplan.example.com/hampton/cart-roadmap", excluding: plan.id
      )
      expect(target).to be_nil
      expect(type).to eq("link")
    end

    it "keeps a non-plan classification and skips resolution" do
      expect(described_class.resolve_link("https://github.com/org/repo/pull/1"))
        .to eq([ "pull_request", nil ])
    end
  end

  describe "scopes" do
    let(:plan) { create(:plan) }

    it ".extracted returns only extracted references" do
      extracted = create(:reference, :extracted, plan: plan, url: "https://a.com")
      create(:reference, plan: plan, url: "https://b.com", source: "explicit")

      expect(described_class.extracted).to eq([ extracted ])
    end

    it ".explicit returns only explicit references" do
      create(:reference, :extracted, plan: plan, url: "https://a.com")
      explicit = create(:reference, plan: plan, url: "https://b.com", source: "explicit")

      expect(described_class.explicit).to eq([ explicit ])
    end
  end
end
