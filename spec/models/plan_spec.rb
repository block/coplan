require "rails_helper"

RSpec.describe Plan, type: :model do
  it "is valid with valid attributes" do
    plan = create(:plan)
    expect(plan).to be_valid
  end

  it "requires title" do
    plan = build(:plan, title: nil)
    expect(plan).not_to be_valid
    expect(plan.errors[:title]).to include("can't be blank")
  end

  it "validates status inclusion" do
    plan = create(:plan)
    plan.status = "invalid"
    expect(plan).not_to be_valid
  end

  it "defaults status to brainstorm" do
    plan = Plan.new
    expect(plan.status).to eq("brainstorm")
  end

  it "returns current content from version" do
    plan = create(:plan)
    expect(plan.current_content).to include("Plan Content")
  end

  it "returns id for to_param" do
    plan = create(:plan)
    expect(plan.to_param).to eq(plan.id)
  end
end
