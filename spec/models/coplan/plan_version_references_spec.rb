require "rails_helper"

RSpec.describe "PlanVersion reference extraction", type: :model do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }

  it "extracts references when a new version is created" do
    CoPlan::PlanVersion.create!(
      plan: plan,
      revision: plan.current_revision + 1,
      content_markdown: "See [Rails](https://rubyonrails.org) for details.",
      actor_type: "human",
      actor_id: user.id
    )

    expect(plan.references.count).to eq(1)
    expect(plan.references.first.url).to eq("https://rubyonrails.org")
  end
end
