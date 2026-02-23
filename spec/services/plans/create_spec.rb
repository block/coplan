require "rails_helper"

RSpec.describe Plans::Create do
  it "creates plan with initial version" do
    user = create(:user)
    plan = Plans::Create.call(
      title: "New Plan",
      content: "# New Plan\n\nSome content.",
      user: user
    )

    expect(plan).to be_persisted
    expect(plan.title).to eq("New Plan")
    expect(plan.status).to eq("brainstorm")
    expect(plan.created_by_user).to eq(user)
    expect(plan.organization).to eq(user.organization)
    expect(plan.current_revision).to eq(1)
    expect(plan.plan_versions.count).to eq(1)

    version = plan.current_plan_version
    expect(version.content_markdown).to eq("# New Plan\n\nSome content.")
    expect(version.revision).to eq(1)
    expect(version.actor_type).to eq("human")
    expect(version.actor_id).to eq(user.id)
    expect(version.content_sha256).to be_present
  end
end
