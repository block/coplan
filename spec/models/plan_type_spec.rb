require "rails_helper"

RSpec.describe CoPlan::PlanType, type: :model do
  it "is valid with valid attributes" do
    plan_type = create(:plan_type)
    expect(plan_type).to be_valid
  end

  it "requires name" do
    plan_type = build(:plan_type, name: nil)
    expect(plan_type).not_to be_valid
    expect(plan_type.errors[:name]).to include("can't be blank")
  end

  it "validates name uniqueness" do
    create(:plan_type, name: "RFC")
    duplicate = build(:plan_type, name: "RFC")
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:name]).to include("has already been taken")
  end

  it "defaults default_tags to empty array" do
    plan_type = CoPlan::PlanType.new
    expect(plan_type.default_tags).to eq([])
  end

  it "defaults metadata to empty hash" do
    plan_type = CoPlan::PlanType.new
    expect(plan_type.metadata).to eq({})
  end

  it "has many plans" do
    plan_type = create(:plan_type)
    plan = create(:plan, plan_type: plan_type)
    expect(plan_type.plans).to include(plan)
  end

  it "nullifies plans when destroyed" do
    plan_type = create(:plan_type)
    plan = create(:plan, plan_type: plan_type)
    plan_type.destroy!
    expect(plan.reload.plan_type_id).to be_nil
  end
end
