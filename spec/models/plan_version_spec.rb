require "rails_helper"

RSpec.describe CoPlan::PlanVersion, type: :model do
  it "is valid with valid attributes" do
    plan = create(:plan)
    version = plan.current_plan_version
    expect(version).to be_valid
  end

  it "computes sha256 automatically" do
    version = build(:plan_version, content_markdown: "test content", content_sha256: nil)
    expect(version).to be_valid
    expect(version.content_sha256).to eq(Digest::SHA256.hexdigest("test content"))
  end

  it "validates revision uniqueness per plan" do
    plan = create(:plan)
    existing_version = plan.current_plan_version
    version = build(:plan_version, plan: plan, revision: existing_version.revision)
    expect(version).not_to be_valid
    expect(version.errors[:revision]).to include("has already been taken")
  end

  it "validates actor_type inclusion" do
    version = build(:plan_version, actor_type: "robot")
    expect(version).not_to be_valid
  end
end
