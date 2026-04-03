require "rails_helper"

RSpec.describe CoPlan::PlanTag, type: :model do
  it "is valid with valid attributes" do
    plan_tag = create(:plan_tag)
    expect(plan_tag).to be_valid
  end

  it "requires unique tag per plan" do
    plan = create(:plan)
    tag = create(:tag)
    create(:plan_tag, plan: plan, tag: tag)
    duplicate = build(:plan_tag, plan: plan, tag: tag)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:tag_id]).to include("has already been taken")
  end

  it "belongs to plan" do
    plan_tag = create(:plan_tag)
    expect(plan_tag.plan).to be_a(CoPlan::Plan)
  end

  it "belongs to tag" do
    plan_tag = create(:plan_tag)
    expect(plan_tag.tag).to be_a(CoPlan::Tag)
  end
end
