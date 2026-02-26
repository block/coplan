require "rails_helper"

RSpec.describe CoPlan::CommentThread, "anchor tracking" do
  let(:user) { create(:user) }
  let(:content) { "# My Plan\n\nFirst section.\n\n## Goals\n\nWe should use unit tests.\n\n## Timeline\n\nQ1 2026." }
  let(:plan) do
    plan = CoPlan::Plan.create!(title: "Test", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: plan, revision: 1,
      content_markdown: content, actor_type: "human", actor_id: user.id
    )
    plan.update!(current_plan_version: version, current_revision: 1)
    plan
  end

  describe "resolve_anchor_position on create" do
    it "resolves anchor_text to character positions" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )
      expect(thread.anchor_start).to be_present
      expect(thread.anchor_end).to be_present
      expect(thread.anchor_revision).to eq(1)
      expect(content[thread.anchor_start...thread.anchor_end]).to eq("unit tests")
    end

    it "handles missing anchor_text gracefully" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user
      )
      expect(thread.anchor_start).to be_nil
    end
  end

  describe "mark_out_of_date_for_new_version! with positions" do
    it "does NOT mark outdated when edit is in unrelated section" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )

      # Edit the timeline section (after the anchor)
      new_content = content.sub("Q1 2026", "Q2 2026")
      anchor_pos = content.index("Q1 2026")
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human", actor_id: user.id,
        operations_json: [{ "op" => "replace_exact", "resolved_range" => [anchor_pos, anchor_pos + 7], "new_range" => [anchor_pos, anchor_pos + 7], "delta" => 0 }]
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      CoPlan::CommentThread.mark_out_of_date_for_new_version!(version2)
      thread.reload
      expect(thread.out_of_date).to be false
    end

    it "marks outdated when edit overlaps with anchor" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )

      # Edit that directly modifies the anchored text
      unit_test_pos = content.index("unit tests")
      new_content = content.sub("unit tests", "integration tests")
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human", actor_id: user.id,
        operations_json: [{ "op" => "replace_exact", "resolved_range" => [unit_test_pos, unit_test_pos + 10], "new_range" => [unit_test_pos, unit_test_pos + 17], "delta" => 7 }]
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      CoPlan::CommentThread.mark_out_of_date_for_new_version!(version2)
      thread.reload
      expect(thread.out_of_date).to be true
    end

    it "shifts anchor positions when edit is before anchor" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )
      original_start = thread.anchor_start

      # Insert text before the anchor
      new_content = content.sub("First section.", "First longer section with more detail.")
      first_pos = content.index("First section.")
      first_len = "First section.".length
      new_len = "First longer section with more detail.".length
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human", actor_id: user.id,
        operations_json: [{ "op" => "replace_exact", "resolved_range" => [first_pos, first_pos + first_len], "new_range" => [first_pos, first_pos + new_len], "delta" => new_len - first_len }]
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      CoPlan::CommentThread.mark_out_of_date_for_new_version!(version2)
      thread.reload
      expect(thread.out_of_date).to be false
      expect(thread.anchor_start).to eq(original_start + (new_len - first_len))
    end

    it "marks out-of-date when thread lacks positional data" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )
      thread.update_columns(anchor_start: nil, anchor_end: nil, anchor_revision: nil)

      new_content = content.sub("Q1 2026", "Q2 2026")
      anchor_pos = content.index("Q1 2026")
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human", actor_id: user.id,
        operations_json: [{ "op" => "replace_exact", "resolved_range" => [anchor_pos, anchor_pos + 7], "new_range" => [anchor_pos, anchor_pos + 7], "delta" => 0 }]
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      CoPlan::CommentThread.mark_out_of_date_for_new_version!(version2)
      thread.reload
      expect(thread.out_of_date).to be true
    end
  end

  describe "#anchor_valid?" do
    it "returns true for non-outdated thread" do
      thread = create(:comment_thread, plan: plan, anchor_text: "some text")
      expect(thread.anchor_valid?).to be true
    end

    it "returns false for outdated thread" do
      thread = create(:comment_thread, plan: plan, anchor_text: "some text", out_of_date: true)
      expect(thread.anchor_valid?).to be false
    end

    it "returns true for non-anchored thread" do
      thread = create(:comment_thread, plan: plan)
      expect(thread.anchor_valid?).to be true
    end
  end

  describe "#anchor_context_with_highlight" do
    it "returns context around the anchor with bold markers" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )

      context = thread.anchor_context_with_highlight(chars: 20)
      expect(context).to include("**unit tests**")
    end

    it "returns nil for non-anchored threads" do
      thread = create(:comment_thread, plan: plan)
      expect(thread.anchor_context_with_highlight).to be_nil
    end
  end
end
