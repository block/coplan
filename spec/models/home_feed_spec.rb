require "rails_helper"

RSpec.describe CoPlan::HomeFeed, type: :model do
  let(:author) { create(:coplan_user) }

  describe ".build" do
    it "reads a born-published plan's creation as its publish moment" do
      plan = create(:plan, :published, created_by_user: author)
      plan.current_plan_version.update!(created_at: 2.days.ago)

      items = described_class.build
      item = items.find { |i| i.plan.id == plan.id }
      expect(item.published).to be(true)
    end

    it "does not report a born-draft plan's creation day as a publish" do
      plan = create(:plan, :draft, created_by_user: author)
      plan.current_plan_version.update!(created_at: 3.days.ago)

      # Published a day later — the publish event is the only publish moment.
      plan.update!(visibility: "published")
      create(:plan_event, plan: plan, event_type: "published",
             actor_id: author.id, created_at: 2.days.ago)

      items = described_class.build.select { |i| i.plan.id == plan.id }
      published_days = items.select(&:published).map(&:date)
      expect(published_days).to contain_exactly(2.days.ago.to_date)
    end
  end
end
