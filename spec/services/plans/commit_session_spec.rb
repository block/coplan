require "rails_helper"

RSpec.describe CoPlan::Plans::CommitSession do
  let(:org) { create(:organization) }
  let(:user) { create(:user, organization: org) }
  let(:content) { "# My Plan\n\nFirst section content.\n\n## Goals\n\nWe should use unit tests.\n\n## Timeline\n\nQ1 2026 delivery." }
  let(:plan) do
    plan = CoPlan::Plan.create!(title: "Test Plan", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: plan, revision: 1,
      content_markdown: content, actor_type: "human", actor_id: user.id
    )
    plan.update!(current_plan_version: version, current_revision: 1)
    plan
  end

  def build_session(plan:, operations_json: [], draft_content: nil, base_revision: nil, **attrs)
    CoPlan::EditSession.create!(
      plan: plan,
      actor_type: "local_agent",
      actor_id: SecureRandom.uuid_v7,
      base_revision: base_revision || plan.current_revision,
      status: "open",
      operations_json: operations_json,
      draft_content: draft_content,
      expires_at: 1.hour.from_now,
      **attrs
    )
  end

  describe "happy path" do
    it "commits a session with operations, creating a PlanVersion" do
      new_content = content.sub("unit tests", "integration tests")
      session = build_session(
        plan: plan,
        operations_json: [{ "op" => "replace_exact", "old_text" => "unit tests", "new_text" => "integration tests" }],
        draft_content: new_content
      )

      result = described_class.call(session: session)

      expect(result[:version]).to be_a(CoPlan::PlanVersion)
      expect(result[:version].content_markdown).to eq(new_content)
      expect(result[:session].reload.status).to eq("committed")
      expect(result[:session].committed_at).to be_present
      expect(result[:session].plan_version_id).to eq(result[:version].id)
      expect(CoPlan::PlanVersion.where(plan: plan).count).to eq(2)
    end

    it "commits a session with 0 operations without creating a PlanVersion" do
      session = build_session(plan: plan, operations_json: [])

      result = described_class.call(session: session)

      expect(result[:version]).to be_nil
      expect(result[:session].reload.status).to eq("committed")
      expect(result[:session].committed_at).to be_present
      expect(CoPlan::PlanVersion.where(plan: plan).count).to eq(1)
    end

    it "uses change_summary from param when provided" do
      new_content = content.sub("unit tests", "integration tests")
      session = build_session(
        plan: plan,
        operations_json: [{ "op" => "replace_exact", "old_text" => "unit tests", "new_text" => "integration tests" }],
        draft_content: new_content,
        change_summary: "session summary"
      )

      result = described_class.call(session: session, change_summary: "param summary")

      expect(result[:version].change_summary).to eq("param summary")
      expect(result[:session].reload.change_summary).to eq("param summary")
    end

    it "uses change_summary from session when param is nil" do
      new_content = content.sub("unit tests", "integration tests")
      session = build_session(
        plan: plan,
        operations_json: [{ "op" => "replace_exact", "old_text" => "unit tests", "new_text" => "integration tests" }],
        draft_content: new_content,
        change_summary: "session summary"
      )

      result = described_class.call(session: session)

      expect(result[:version].change_summary).to eq("session summary")
    end
  end

  describe "version creation" do
    let(:new_content) { content.sub("unit tests", "integration tests") }
    let(:session) do
      build_session(
        plan: plan,
        operations_json: [{ "op" => "replace_exact", "old_text" => "unit tests", "new_text" => "integration tests" }],
        draft_content: new_content
      )
    end

    it "sets revision to current_revision + 1" do
      result = described_class.call(session: session)

      expect(result[:version].revision).to eq(2)
      expect(plan.reload.current_revision).to eq(2)
    end

    it "includes operations_json from the session" do
      result = described_class.call(session: session)

      expect(result[:version].operations_json).to be_present
      expect(result[:version].operations_json.first["op"]).to eq("replace_exact")
    end

    it "computes diff_unified correctly" do
      result = described_class.call(session: session)

      expect(result[:version].diff_unified).to include("-We should use unit tests.")
      expect(result[:version].diff_unified).to include("+We should use integration tests.")
    end

    it "copies actor_type and actor_id from session" do
      session = build_session(
        plan: plan,
        operations_json: [{ "op" => "replace_exact", "old_text" => "unit tests", "new_text" => "integration tests" }],
        draft_content: new_content,
        actor_type: "cloud_persona",
        actor_id: "persona-123"
      )

      result = described_class.call(session: session)

      expect(result[:version].actor_type).to eq("cloud_persona")
      expect(result[:version].actor_id).to eq("persona-123")
    end
  end

  describe "rebase (stale base_revision)" do
    it "rebases non-overlapping edits successfully" do
      # Session was opened at revision 1
      session = build_session(
        plan: plan,
        base_revision: 1,
        operations_json: [{ "op" => "replace_exact", "old_text" => "Q1 2026 delivery.", "new_text" => "Q2 2026 delivery." }],
        draft_content: content.sub("Q1 2026 delivery.", "Q2 2026 delivery.")
      )

      # Meanwhile, someone else edits the beginning (creates revision 2)
      v2_content = content.sub("First section content.", "Updated first section.")
      old_text = "First section content."
      new_text = "Updated first section."
      start_pos = content.index(old_text)
      end_pos = start_pos + old_text.length
      CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: v2_content, actor_type: "human", actor_id: user.id,
        operations_json: [{
          "op" => "replace_exact",
          "old_text" => old_text,
          "new_text" => new_text,
          "resolved_range" => [start_pos, end_pos],
          "new_range" => [start_pos, start_pos + new_text.length],
          "delta" => new_text.length - old_text.length
        }]
      )
      plan.update!(current_revision: 2, current_plan_version: CoPlan::PlanVersion.find_by(plan: plan, revision: 2))

      result = described_class.call(session: session)

      expect(result[:version]).to be_a(CoPlan::PlanVersion)
      expect(result[:version].revision).to eq(3)
      expect(result[:version].content_markdown).to include("Updated first section.")
      expect(result[:version].content_markdown).to include("Q2 2026 delivery.")
      expect(result[:version].content_markdown).not_to include("Q1 2026 delivery.")
    end

    it "raises SessionConflictError for overlapping edits" do
      # Session was opened at revision 1, wants to edit "unit tests"
      session = build_session(
        plan: plan,
        base_revision: 1,
        operations_json: [{
          "op" => "replace_exact",
          "old_text" => "We should use unit tests.",
          "new_text" => "We should use integration tests.",
          "resolved_range" => [content.index("We should use unit tests."), content.index("We should use unit tests.") + "We should use unit tests.".length],
          "new_range" => [content.index("We should use unit tests."), content.index("We should use unit tests.") + "We should use integration tests.".length],
          "delta" => "integration tests".length - "unit tests".length
        }],
        draft_content: content.sub("We should use unit tests.", "We should use integration tests.")
      )

      # Meanwhile, someone else also edits "unit tests" (creates revision 2)
      v2_content = content.sub("We should use unit tests.", "We should use acceptance tests.")
      old_text = "We should use unit tests."
      new_text = "We should use acceptance tests."
      start_pos = content.index(old_text)
      end_pos = start_pos + old_text.length
      CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: v2_content, actor_type: "human", actor_id: user.id,
        operations_json: [{
          "op" => "replace_exact",
          "old_text" => old_text,
          "new_text" => new_text,
          "resolved_range" => [start_pos, end_pos],
          "new_range" => [start_pos, start_pos + new_text.length],
          "delta" => new_text.length - old_text.length
        }]
      )
      plan.update!(current_revision: 2, current_plan_version: CoPlan::PlanVersion.find_by(plan: plan, revision: 2))

      expect {
        described_class.call(session: session)
      }.to raise_error(CoPlan::Plans::CommitSession::SessionConflictError)
    end
  end

  describe "edge cases" do
    it "raises error for non-open session" do
      session = build_session(plan: plan)
      session.update!(status: "committed", committed_at: Time.current)

      expect {
        described_class.call(session: session)
      }.to raise_error("Session is not open")
    end

    it "raises error for already-committed session" do
      session = build_session(plan: plan)
      session.update!(status: "committed", committed_at: Time.current)

      expect {
        described_class.call(session: session)
      }.to raise_error("Session is not open")
    end

    it "raises StaleSessionError when >20 revisions behind" do
      session = build_session(
        plan: plan,
        base_revision: 1,
        operations_json: [{ "op" => "replace_exact", "old_text" => "unit tests", "new_text" => "integration tests" }],
        draft_content: content.sub("unit tests", "integration tests")
      )

      # Create 21 intervening versions
      current_content = content
      21.times do |i|
        rev = i + 2
        new_content = current_content + "\n\nRevision #{rev} content."
        CoPlan::PlanVersion.create!(
          plan: plan, revision: rev,
          content_markdown: new_content, actor_type: "human", actor_id: user.id,
          operations_json: []
        )
        current_content = new_content
      end
      plan.update!(current_revision: 22, current_plan_version: CoPlan::PlanVersion.find_by(plan: plan, revision: 22))

      expect {
        described_class.call(session: session)
      }.to raise_error(CoPlan::Plans::CommitSession::StaleSessionError, /too stale.*21 revisions behind/)
    end

    it "calls mark_out_of_date_for_new_version! on comment threads" do
      new_content = content.sub("unit tests", "integration tests")
      session = build_session(
        plan: plan,
        operations_json: [{ "op" => "replace_exact", "old_text" => "unit tests", "new_text" => "integration tests" }],
        draft_content: new_content
      )

      # Create a comment thread anchored to text that will change
      comment_thread = CoPlan::CommentThread.create!(
        plan: plan,
        plan_version: plan.current_plan_version,
        created_by_user: user,
        status: "open",
        anchor_text: "We should use unit tests."
      )

      result = described_class.call(session: session)

      comment_thread.reload
      expect(comment_thread.out_of_date).to be true
      expect(comment_thread.out_of_date_since_version_id).to eq(result[:version].id)
    end
  end

  describe "concurrent sessions" do
    it "both commit successfully when edits don't overlap" do
      # Session A edits the beginning
      session_a = build_session(
        plan: plan,
        base_revision: 1,
        operations_json: [{ "op" => "replace_exact", "old_text" => "First section content.", "new_text" => "Updated first section." }],
        draft_content: content.sub("First section content.", "Updated first section.")
      )

      # Session B edits the end
      session_b = build_session(
        plan: plan,
        base_revision: 1,
        operations_json: [{ "op" => "replace_exact", "old_text" => "Q1 2026 delivery.", "new_text" => "Q2 2026 delivery." }],
        draft_content: content.sub("Q1 2026 delivery.", "Q2 2026 delivery.")
      )

      # Commit A first
      result_a = described_class.call(session: session_a)
      expect(result_a[:version].revision).to eq(2)
      expect(plan.reload.current_revision).to eq(2)

      # Now commit B — must rebase against A's changes
      result_b = described_class.call(session: session_b)
      expect(result_b[:version].revision).to eq(3)

      final_content = result_b[:version].content_markdown
      expect(final_content).to include("Updated first section.")
      expect(final_content).to include("Q2 2026 delivery.")
      expect(final_content).not_to include("First section content.")
      expect(final_content).not_to include("Q1 2026 delivery.")
    end

    it "second commit fails when edits overlap" do
      # Both sessions edit the same text
      session_a = build_session(
        plan: plan,
        base_revision: 1,
        operations_json: [{ "op" => "replace_exact", "old_text" => "We should use unit tests.", "new_text" => "We should use integration tests." }],
        draft_content: content.sub("We should use unit tests.", "We should use integration tests.")
      )

      session_b = build_session(
        plan: plan,
        base_revision: 1,
        operations_json: [{ "op" => "replace_exact", "old_text" => "We should use unit tests.", "new_text" => "We should use acceptance tests." }],
        draft_content: content.sub("We should use unit tests.", "We should use acceptance tests.")
      )

      # Commit A first — succeeds
      result_a = described_class.call(session: session_a)
      expect(result_a[:version].revision).to eq(2)

      # Commit B — should fail because the text was already changed
      expect {
        described_class.call(session: session_b)
      }.to raise_error(CoPlan::Plans::OperationError)
    end
  end

  describe "committing a non-open session" do
    it "raises SessionNotOpenError for a committed session" do
      session = build_session(plan: plan, operations_json: [], draft_content: content)
      session.update!(status: "committed", committed_at: Time.current)

      expect {
        described_class.call(session: session)
      }.to raise_error(CoPlan::Plans::CommitSession::SessionNotOpenError, /not open/)
    end

    it "raises SessionNotOpenError for a cancelled session" do
      session = build_session(plan: plan, operations_json: [], draft_content: content)
      session.update!(status: "cancelled")

      expect {
        described_class.call(session: session)
      }.to raise_error(CoPlan::Plans::CommitSession::SessionNotOpenError, /not open/)
    end
  end
end
