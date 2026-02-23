require "rails_helper"

RSpec.describe AutomatedPlanReviewer, type: :model do
  let(:org) { create(:organization) }

  it "is valid with valid attributes" do
    reviewer = create(:automated_plan_reviewer, organization: org)
    expect(reviewer).to be_valid
  end

  it "requires key" do
    reviewer = build(:automated_plan_reviewer, key: nil)
    expect(reviewer).not_to be_valid
    expect(reviewer.errors[:key]).to include("can't be blank")
  end

  it "requires name" do
    reviewer = build(:automated_plan_reviewer, name: nil)
    expect(reviewer).not_to be_valid
    expect(reviewer.errors[:name]).to include("can't be blank")
  end

  it "requires prompt_text" do
    reviewer = build(:automated_plan_reviewer, prompt_text: nil)
    expect(reviewer).not_to be_valid
    expect(reviewer.errors[:prompt_text]).to include("can't be blank")
  end

  it "requires ai_model" do
    reviewer = build(:automated_plan_reviewer, ai_model: nil)
    expect(reviewer).not_to be_valid
    expect(reviewer.errors[:ai_model]).to include("can't be blank")
  end

  it "requires organization" do
    reviewer = build(:automated_plan_reviewer, organization: nil)
    expect(reviewer).not_to be_valid
    expect(reviewer.errors[:organization]).to include("must exist")
  end

  it "validates key format" do
    reviewer = build(:automated_plan_reviewer, organization: org, key: "Invalid Key!")
    expect(reviewer).not_to be_valid
    expect(reviewer.errors[:key]).to include("only allows lowercase letters, numbers, and hyphens")
  end

  it "validates key uniqueness scoped to organization" do
    existing = create(:automated_plan_reviewer, organization: org)
    duplicate = build(:automated_plan_reviewer, organization: org, key: existing.key)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:key]).to include("has already been taken")
  end

  it "allows same key in different organizations" do
    other_org = create(:organization)
    create(:automated_plan_reviewer, organization: org, key: "same-key")
    reviewer = build(:automated_plan_reviewer, organization: other_org, key: "same-key")
    expect(reviewer).to be_valid
  end

  it "stores prompt text" do
    reviewer = create(:automated_plan_reviewer, organization: org, prompt_text: "Review for security issues")
    expect(reviewer.prompt_text).to include("security")
  end

  it "triggers_on_status? returns true for matching status" do
    reviewer = create(:automated_plan_reviewer, organization: org, trigger_statuses: ["considering"])
    expect(reviewer.triggers_on_status?("considering")).to be true
  end

  it "triggers_on_status? returns false for non-matching status" do
    reviewer = create(:automated_plan_reviewer, organization: org, trigger_statuses: ["considering"])
    expect(reviewer.triggers_on_status?("brainstorm")).to be false
  end

  it "enabled scope returns only enabled reviewers" do
    enabled_reviewer = create(:automated_plan_reviewer, organization: org, enabled: true)
    disabled_reviewer = create(:automated_plan_reviewer, organization: org, enabled: false)
    enabled = AutomatedPlanReviewer.enabled
    expect(enabled).to include(enabled_reviewer)
    expect(enabled).not_to include(disabled_reviewer)
  end

  it "validates ai_provider inclusion" do
    reviewer = build(:automated_plan_reviewer, organization: org, ai_provider: "unknown-provider")
    expect(reviewer).not_to be_valid
    expect(reviewer.errors[:ai_provider]).to include("is not included in the list")
  end

  it "accepts valid ai_providers" do
    AutomatedPlanReviewer::AI_PROVIDERS.each do |provider|
      reviewer = build(:automated_plan_reviewer, organization: org, ai_provider: provider)
      expect(reviewer).to be_valid, "Expected #{provider} to be valid"
    end
  end

  it "defaults ai_provider to openai" do
    reviewer = AutomatedPlanReviewer.new
    expect(reviewer.ai_provider).to eq("openai")
  end

  it "validates trigger_statuses against Plan::STATUSES" do
    reviewer = build(:automated_plan_reviewer, organization: org, trigger_statuses: ["considering", "invalid-status"])
    expect(reviewer).not_to be_valid
    expect(reviewer.errors[:trigger_statuses].any? { |e| e.include?("invalid-status") }).to be true
  end

  it "accepts valid trigger_statuses" do
    reviewer = build(:automated_plan_reviewer, organization: org, trigger_statuses: Plan::STATUSES.dup)
    expect(reviewer).to be_valid
  end

  it "accepts empty trigger_statuses" do
    reviewer = build(:automated_plan_reviewer, organization: org, trigger_statuses: [])
    expect(reviewer).to be_valid
  end

  it "defaults trigger_statuses to empty array" do
    reviewer = AutomatedPlanReviewer.new
    expect(reviewer.trigger_statuses).to eq([])
  end

  it "defaults enabled to true" do
    reviewer = AutomatedPlanReviewer.new
    expect(reviewer.enabled).to be true
  end

  it "create_defaults_for creates default reviewers for an organization" do
    org = Organization.create!(name: "Test Org", slug: "test-defaults-org-spec")
    reviewers = org.automated_plan_reviewers
    expect(reviewers.count).to eq(3)
    expect(reviewers.pluck(:key).sort).to eq(%w[routing-reviewer scalability-reviewer security-reviewer])
    reviewers.each do |r|
      expect(r.prompt_text).to be_present
      expect(r.ai_model).to be_present
    end
  end

  it "create_defaults_for is idempotent" do
    AutomatedPlanReviewer.create_defaults_for(org)
    initial_count = org.automated_plan_reviewers.count
    AutomatedPlanReviewer.create_defaults_for(org)
    expect(org.automated_plan_reviewers.count).to eq(initial_count)
  end
end
