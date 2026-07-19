require "rails_helper"

# `listed?` is THE discovery predicate (mirrored by Plan.visible_to) — every
# list, feed, count, and shelf answers through it. These specs pin the
# drafts-are-unlisted-not-locked contract so a regression here fails loudly
# instead of leaking someone's draft into a feed.
RSpec.describe CoPlan::PlanPolicy do
  let(:author) { create(:coplan_user) }
  let(:other_user) { create(:coplan_user) }

  describe "#show?" do
    it "allows anyone with the URL to read a draft (unlisted, not locked)" do
      draft = create(:plan, :draft, created_by_user: author)
      expect(described_class.new(other_user, draft).show?).to be(true)
    end
  end

  describe "#listed?" do
    it "lists published plans for everyone" do
      plan = create(:plan, :published, created_by_user: author)
      expect(described_class.new(other_user, plan).listed?).to be(true)
    end

    it "lists a draft for its author" do
      draft = create(:plan, :draft, created_by_user: author)
      expect(described_class.new(author, draft).listed?).to be(true)
    end

    it "never lists someone else's draft" do
      draft = create(:plan, :draft, created_by_user: author)
      expect(described_class.new(other_user, draft).listed?).to be(false)
    end

    it "does not list a draft for a nil user" do
      draft = create(:plan, :draft, created_by_user: author)
      expect(described_class.new(nil, draft).listed?).to be(false)
    end
  end

  describe "#contribute?" do
    it "lets any signed-in user add references and attachments" do
      plan = create(:plan, :published, created_by_user: author)
      expect(described_class.new(other_user, plan).contribute?).to be(true)
    end

    it "forbids contributions from signed-out visitors" do
      plan = create(:plan, :published, created_by_user: author)
      expect(described_class.new(nil, plan).contribute?).to be(false)
    end
  end

  describe "#publish?" do
    it "allows the author to publish their draft" do
      draft = create(:plan, :draft, created_by_user: author)
      expect(described_class.new(author, draft).publish?).to be(true)
    end

    it "does not apply to already-shared plans (that's hide?'s side)" do
      plan = create(:plan, :published, created_by_user: author)
      expect(described_class.new(author, plan).publish?).to be(false)
    end

    it "forbids publishing someone else's draft" do
      draft = create(:plan, :draft, created_by_user: author)
      expect(described_class.new(other_user, draft).publish?).to be(false)
    end
  end

  describe "#hide?" do
    it "lets the author take a shared plan back to Private" do
      plan = create(:plan, :published, created_by_user: author)
      expect(described_class.new(author, plan).hide?).to be(true)
    end

    it "does not apply to drafts (already hidden) or archived plans" do
      draft = create(:plan, :draft, created_by_user: author)
      archived = create(:plan, :archived, created_by_user: author)
      expect(described_class.new(author, draft).hide?).to be(false)
      expect(described_class.new(author, archived).hide?).to be(false)
    end

    it "forbids hiding someone else's plan" do
      plan = create(:plan, :published, created_by_user: author)
      expect(described_class.new(other_user, plan).hide?).to be(false)
    end
  end
end
