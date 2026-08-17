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

  it "cannot be destroyed while plans use it — nullify would mint untyped plans" do
    plan_type = create(:plan_type)
    plan = create(:plan, plan_type: plan_type)

    expect(plan_type.destroy).to be(false)
    expect(plan_type.errors[:base]).to be_present
    expect(plan.reload.plan_type_id).to eq(plan_type.id)
  end

  it "can be destroyed once no plans use it" do
    plan_type = create(:plan_type)
    expect { plan_type.destroy! }.to change(CoPlan::PlanType, :count).by(-1)
  end

  describe ".general" do
    it "returns the existing General type, matched case-insensitively" do
      existing = create(:plan_type, name: "general")
      expect(CoPlan::PlanType.general).to eq(existing)
    end

    it "recreates the General type when missing" do
      # A migrated database always has General (RequirePlanTypeOnCoplanPlans
      # seeds it) — remove it to exercise the self-healing branch.
      CoPlan::PlanType.find_by_name("General")&.destroy!
      general = CoPlan::PlanType.general
      expect(general.name).to eq("General")
      expect(general).to be_persisted
    end
  end
end
