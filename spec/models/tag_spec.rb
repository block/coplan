require "rails_helper"

RSpec.describe CoPlan::Tag, type: :model do
  it "is valid with valid attributes" do
    tag = create(:tag)
    expect(tag).to be_valid
  end

  it "requires name" do
    tag = build(:tag, name: nil)
    expect(tag).not_to be_valid
    expect(tag.errors[:name]).to include("can't be blank")
  end

  it "requires unique name" do
    create(:tag, name: "infrastructure")
    tag = build(:tag, name: "infrastructure")
    expect(tag).not_to be_valid
    expect(tag.errors[:name]).to include("has already been taken")
  end

  it "has many plans through plan_tags" do
    tag = create(:tag)
    plan = create(:plan)
    create(:plan_tag, plan: plan, tag: tag)
    expect(tag.plans).to include(plan)
  end

  it "updates plans_count via counter cache" do
    tag = create(:tag)
    plan = create(:plan)
    expect { create(:plan_tag, plan: plan, tag: tag) }.to change { tag.reload.plans_count }.from(0).to(1)
  end

  describe "Plan#tag_names=" do
    it "creates Tag and PlanTag records" do
      plan = create(:plan)
      plan.tag_names = ["infrastructure", "api-design"]
      expect(plan.tag_names).to match_array(["infrastructure", "api-design"])
      expect(CoPlan::Tag.where(name: "infrastructure")).to exist
    end

    it "reuses existing Tag records" do
      create(:tag, name: "security")
      plan = create(:plan)
      expect { plan.tag_names = ["security"] }.not_to change(CoPlan::Tag, :count)
      expect(plan.tag_names).to eq(["security"])
    end

    it "removes old associations when tags change" do
      plan = create(:plan)
      plan.tag_names = ["alpha", "beta"]
      plan.tag_names = ["beta", "gamma"]
      expect(plan.tag_names).to match_array(["beta", "gamma"])
    end

    it "handles blank and duplicate names" do
      plan = create(:plan)
      plan.tag_names = ["  infra  ", "infra", "", "api"]
      expect(plan.tag_names).to match_array(["infra", "api"])
    end
  end
end
