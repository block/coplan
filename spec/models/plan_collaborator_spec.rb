require "rails_helper"

RSpec.describe CoPlan::PlanCollaborator, type: :model do
  it "is valid with valid attributes" do
    collaborator = create(:plan_collaborator)
    expect(collaborator).to be_valid
  end

  it "requires role" do
    collaborator = build(:plan_collaborator, role: nil)
    expect(collaborator).not_to be_valid
  end

  it "validates role inclusion" do
    collaborator = build(:plan_collaborator, role: "admin")
    expect(collaborator).not_to be_valid
  end

  it "allows all valid roles" do
    plan = create(:plan)
    CoPlan::PlanCollaborator::ROLES.each do |role|
      user = create(:coplan_user)
      attrs = { plan: plan, user: user, role: role }
      attrs[:highlighted_reason] = "Top expert" if role == "highlighted"
      collaborator = build(:plan_collaborator, **attrs)
      expect(collaborator).to be_valid, "Expected role '#{role}' to be valid"
    end
  end

  it "requires unique user per plan" do
    collaborator = create(:plan_collaborator)
    duplicate = build(:plan_collaborator, plan: collaborator.plan, user: collaborator.user)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:user_id]).to include("has already been taken")
  end

  describe "highlighted role" do
    it "requires highlighted_reason" do
      collaborator = build(:plan_collaborator, role: "highlighted", highlighted_reason: nil)
      expect(collaborator).not_to be_valid
      expect(collaborator.errors[:highlighted_reason]).to include("can't be blank")
    end

    it "is valid with highlighted_reason" do
      collaborator = build(:plan_collaborator, role: "highlighted", highlighted_reason: "Domain expert in payments")
      expect(collaborator).to be_valid
    end
  end

  describe "approver role" do
    it "tracks approval via approve!" do
      collaborator = create(:plan_collaborator, :approver)
      expect(collaborator.approved?).to be false

      collaborator.approve!
      expect(collaborator.approved?).to be true
      expect(collaborator.approved_at).to be_present
    end
  end

  describe "role data cleanup" do
    it "clears approved_at when role changes from approver" do
      collaborator = create(:plan_collaborator, :approver)
      collaborator.approve!
      expect(collaborator.approved_at).to be_present

      collaborator.update!(role: "reviewer")
      expect(collaborator.approved_at).to be_nil
    end

    it "clears highlighted_reason when role changes from highlighted" do
      collaborator = create(:plan_collaborator, :highlighted)
      expect(collaborator.highlighted_reason).to be_present

      collaborator.update!(role: "viewer")
      expect(collaborator.highlighted_reason).to be_nil
    end
  end

  describe "scopes" do
    let(:plan) { create(:plan) }

    it ".authors returns only author collaborators" do
      author = create(:plan_collaborator, plan: plan, role: "author")
      create(:plan_collaborator, plan: plan, role: "reviewer")
      expect(plan.plan_collaborators.authors).to eq([author])
    end

    it ".approvers returns only approver collaborators" do
      approver = create(:plan_collaborator, plan: plan, role: "approver")
      create(:plan_collaborator, plan: plan, role: "viewer")
      expect(plan.plan_collaborators.approvers).to eq([approver])
    end

    it ".highlighted returns only highlighted collaborators" do
      highlighted = create(:plan_collaborator, plan: plan, role: "highlighted", highlighted_reason: "Expert")
      create(:plan_collaborator, plan: plan, role: "author")
      expect(plan.plan_collaborators.highlighted).to eq([highlighted])
    end
  end
end
