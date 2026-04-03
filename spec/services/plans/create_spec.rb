require "rails_helper"

RSpec.describe CoPlan::Plans::Create do
  it "creates plan with initial version" do
    user = create(:coplan_user)
    plan = CoPlan::Plans::Create.call(
      title: "New Plan",
      content: "# New Plan\n\nSome content.",
      user: user
    )

    expect(plan).to be_persisted
    expect(plan.title).to eq("New Plan")
    expect(plan.status).to eq("brainstorm")
    expect(plan.created_by_user).to eq(user)
    expect(plan.current_revision).to eq(1)
    expect(plan.plan_versions.count).to eq(1)

    version = plan.current_plan_version
    expect(version.content_markdown).to eq("# New Plan\n\nSome content.")
    expect(version.revision).to eq(1)
    expect(version.actor_type).to eq("human")
    expect(version.actor_id).to eq(user.id)
    expect(version.content_sha256).to be_present
  end

  it "creates plan with plan_type" do
    user = create(:coplan_user)
    plan_type = create(:plan_type)
    plan = CoPlan::Plans::Create.call(
      title: "Typed Plan",
      content: "# Typed",
      user: user,
      plan_type_id: plan_type.id
    )

    expect(plan).to be_persisted
    expect(plan.plan_type).to eq(plan_type)
  end

  it "creates plan without plan_type" do
    user = create(:coplan_user)
    plan = CoPlan::Plans::Create.call(
      title: "Untyped Plan",
      content: "# Untyped",
      user: user
    )

    expect(plan).to be_persisted
    expect(plan.plan_type_id).to be_nil
  end
end
