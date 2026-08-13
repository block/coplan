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

  it "validates name uniqueness case-insensitively" do
    create(:plan_type, name: "General")
    duplicate = build(:plan_type, name: "GENERAL")
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:name]).to include("has already been taken")
  end

  describe ".find_by_name" do
    it "resolves names case-insensitively regardless of database collation" do
      plan_type = create(:plan_type, name: "General")
      %w[general General GENERAL gEnErAl].each do |name|
        expect(CoPlan::PlanType.find_by_name(name)).to eq(plan_type)
      end
    end

    it "returns nil for unknown or blank names" do
      expect(CoPlan::PlanType.find_by_name("missing")).to be_nil
      expect(CoPlan::PlanType.find_by_name(nil)).to be_nil
    end
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
