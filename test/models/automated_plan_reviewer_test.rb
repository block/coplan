require "test_helper"

class AutomatedPlanReviewerTest < ActiveSupport::TestCase
  test "valid reviewer" do
    reviewer = automated_plan_reviewers(:security_reviewer)
    assert reviewer.valid?
  end

  test "requires key" do
    reviewer = AutomatedPlanReviewer.new(name: "Test", prompt_path: "prompts/reviewers/security.md", ai_model: "gpt-4o")
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:key], "can't be blank"
  end

  test "requires name" do
    reviewer = AutomatedPlanReviewer.new(key: "test", prompt_path: "prompts/reviewers/security.md", ai_model: "gpt-4o")
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:name], "can't be blank"
  end

  test "requires prompt_path" do
    reviewer = AutomatedPlanReviewer.new(key: "test", name: "Test", ai_model: "gpt-4o")
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:prompt_path], "can't be blank"
  end

  test "requires ai_model" do
    reviewer = AutomatedPlanReviewer.new(key: "test", name: "Test", prompt_path: "prompts/reviewers/security.md")
    reviewer.ai_model = nil
    assert_not reviewer.valid?
    assert_includes reviewer.errors[:ai_model], "can't be blank"
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
      prompt_path: "prompts/reviewers/security.md",
      ai_model: "gpt-4o"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
  end

  test "duplicate key rejected for global reviewers" do
    existing = automated_plan_reviewers(:global_reviewer)
    duplicate = AutomatedPlanReviewer.new(
      organization: nil,
      key: existing.key,
      name: "Duplicate Global",
      prompt_path: "prompts/reviewers/routing.md",
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
      prompt_path: "prompts/reviewers/security.md",
      ai_model: "gpt-4o"
    )
    assert reviewer.valid?
  end

  test "validates prompt file exists" do
    reviewer = AutomatedPlanReviewer.new(
      key: "test",
      name: "Test",
      prompt_path: "prompts/reviewers/nonexistent.md",
      ai_model: "gpt-4o"
    )
    assert_not reviewer.valid?
    assert reviewer.errors[:prompt_path].any? { |e| e.include?("does not exist") }
  end

  test "prompt_content reads the prompt file" do
    reviewer = automated_plan_reviewers(:security_reviewer)
    content = reviewer.prompt_content
    assert_includes content, "security"
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

  test "organization is optional (global reviewers)" do
    reviewer = automated_plan_reviewers(:global_reviewer)
    assert_nil reviewer.organization_id
    assert reviewer.valid?
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
end
