require "test_helper"

class AutomatedPlanReviewerTest < ActiveSupport::TestCase
  test "valid reviewer" do
    reviewer = automated_plan_reviewers(:security_reviewer)
    assert reviewer.valid?
  end

  test "requires key" do
    reviewer = AutomatedPlanReviewer.new(name: "Test", prompt_text: "Review this plan.", ai_model: "gpt-4o")
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:key], "can't be blank"
  end

  test "requires name" do
    reviewer = AutomatedPlanReviewer.new(key: "test", prompt_text: "Review this plan.", ai_model: "gpt-4o")
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:name], "can't be blank"
  end

  test "requires prompt_text" do
    reviewer = AutomatedPlanReviewer.new(key: "test", name: "Test", ai_model: "gpt-4o")
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:prompt_text], "can't be blank"
  end

  test "requires ai_model" do
    reviewer = AutomatedPlanReviewer.new(key: "test", name: "Test", prompt_text: "Review this plan.")
    reviewer.ai_model = nil
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:ai_model], "can't be blank"
  end

  test "requires organization" do
    reviewer = AutomatedPlanReviewer.new(
      key: "test",
      name: "Test",
      prompt_text: "Review this plan.",
      ai_model: "gpt-4o"
    )
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:organization], "must exist"
  end

  test "key format only allows lowercase letters, numbers, and hyphens" do
    reviewer = automated_plan_reviewers(:security_reviewer)
    reviewer.key = "Invalid Key!"
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:key], "only allows lowercase letters, numbers, and hyphens"
  end

  test "key uniqueness scoped to organization" do
    existing = automated_plan_reviewers(:security_reviewer)
    duplicate = AutomatedPlanReviewer.new(
      organization: existing.organization,
      key: existing.key,
      name: "Duplicate",
      prompt_text: "Review this plan.",
      ai_model: "gpt-4o"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
  end

  test "same key allowed in different organizations" do
    reviewer = AutomatedPlanReviewer.new(
      organization: organizations(:widgets),
      key: "security-reviewer",
      name: "Security Reviewer",
      prompt_text: "Review this plan.",
      ai_model: "gpt-4o"
    )
    assert reviewer.valid?
  end

  test "prompt_text stores the prompt content" do
    reviewer = automated_plan_reviewers(:security_reviewer)
    assert_includes reviewer.prompt_text, "security"
  end

  test "triggers_on_status? returns true for matching status" do
    reviewer = automated_plan_reviewers(:security_reviewer)
    assert reviewer.triggers_on_status?("considering")
  end

  test "triggers_on_status? returns false for non-matching status" do
    reviewer = automated_plan_reviewers(:security_reviewer)
    assert_not reviewer.triggers_on_status?("brainstorm")
  end

  test "enabled scope returns only enabled reviewers" do
    enabled = AutomatedPlanReviewer.enabled
    assert enabled.include?(automated_plan_reviewers(:security_reviewer))
    assert_not enabled.include?(automated_plan_reviewers(:disabled_reviewer))
  end

  test "defaults ai_provider to openai" do
    reviewer = AutomatedPlanReviewer.new
    assert_equal "openai", reviewer.ai_provider
  end

  test "defaults trigger_statuses to empty array" do
    reviewer = AutomatedPlanReviewer.new
    assert_equal [], reviewer.trigger_statuses
  end

  test "defaults enabled to true" do
    reviewer = AutomatedPlanReviewer.new
    assert_equal true, reviewer.enabled
  end

  test "create_defaults_for creates default reviewers for an organization" do
    org = Organization.create!(name: "Test Org", slug: "test-defaults-org")
    reviewers = org.automated_plan_reviewers
    assert_equal 3, reviewers.count
    assert_equal %w[routing-reviewer scalability-reviewer security-reviewer], reviewers.pluck(:key).sort
    reviewers.each do |r|
      assert r.prompt_text.present?
      assert r.ai_model.present?
    end
  end

  test "create_defaults_for is idempotent" do
    org = organizations(:acme)
    AutomatedPlanReviewer.create_defaults_for(org)
    initial_count = org.automated_plan_reviewers.count
    AutomatedPlanReviewer.create_defaults_for(org)
    assert_equal initial_count, org.automated_plan_reviewers.count
  end
end
