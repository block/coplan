require "rails_helper"

RSpec.describe CoPlan::Plans::ReplaceContent do
  let(:user) { create(:coplan_user) }
  let(:initial_content) do
    <<~MD
      # My Plan

      ## Goals

      We should use unit tests.

      ## Timeline

      Q1 2026 delivery.
    MD
  end
  let!(:plan) do
    plan = CoPlan::Plan.create!(title: "Test Plan", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: plan, revision: 1,
      content_markdown: initial_content,
      actor_type: "human", actor_id: user.id,
      operations_json: []
    )
    plan.update!(current_plan_version: version, current_revision: 1)
    plan
  end

  describe "happy path" do
    let(:new_content) { initial_content.sub("unit tests", "integration tests") }

    it "creates a new PlanVersion with the new content" do
      expect {
        described_class.call(
          plan: plan,
          new_content: new_content,
          base_revision: 1,
          actor_type: "local_agent",
          actor_id: user.id
        )
      }.to change(CoPlan::PlanVersion, :count).by(1)

      version = plan.reload.current_plan_version
      expect(version.content_markdown).to eq(new_content)
      expect(version.revision).to eq(2)
      expect(version.base_revision).to eq(1)
      expect(version.actor_type).to eq("local_agent")
    end

    it "stores positional metadata in operations_json so OT can rebase later anchors" do
      result = described_class.call(
        plan: plan,
        new_content: new_content,
        base_revision: 1,
        actor_type: "local_agent",
        actor_id: user.id
      )

      ops_json = result[:version].operations_json
      expect(ops_json).to be_an(Array).and(be_present)
      ops_json.each do |op|
        expect(op).to have_key("resolved_range")
        expect(op).to have_key("new_range")
      end
    end

    it "computes a diff_unified summary" do
      result = described_class.call(
        plan: plan,
        new_content: new_content,
        base_revision: 1,
        actor_type: "local_agent",
        actor_id: user.id
      )

      expect(result[:version].diff_unified).to include("-We should use unit tests.")
      expect(result[:version].diff_unified).to include("+We should use integration tests.")
    end

    it "carries change_summary onto the version" do
      result = described_class.call(
        plan: plan,
        new_content: new_content,
        base_revision: 1,
        actor_type: "local_agent",
        actor_id: user.id,
        change_summary: "Switched to integration tests"
      )

      expect(result[:version].change_summary).to eq("Switched to integration tests")
    end

    it "is a no-op when content is unchanged" do
      result = described_class.call(
        plan: plan,
        new_content: initial_content,
        base_revision: 1,
        actor_type: "local_agent",
        actor_id: user.id
      )

      expect(result[:no_op]).to be true
      expect(result[:version]).to be_nil
      expect(plan.reload.current_revision).to eq(1)
      expect(CoPlan::PlanVersion.where(plan: plan).count).to eq(1)
    end
  end

  describe "stale revision" do
    it "raises StaleRevisionError when base_revision lags current_revision" do
      # Bump current_revision by adding a version
      v2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: initial_content + "\nappended\n",
        actor_type: "human", actor_id: user.id,
        operations_json: []
      )
      plan.update!(current_plan_version: v2, current_revision: 2)

      expect {
        described_class.call(
          plan: plan,
          new_content: "ignored",
          base_revision: 1,
          actor_type: "local_agent",
          actor_id: user.id
        )
      }.to raise_error(CoPlan::Plans::ReplaceContent::StaleRevisionError) do |err|
        expect(err.current_revision).to eq(2)
      end
    end

    it "does not create a version when stale" do
      v2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: initial_content + "\nappended\n",
        actor_type: "human", actor_id: user.id,
        operations_json: []
      )
      plan.update!(current_plan_version: v2, current_revision: 2)

      expect {
        begin
          described_class.call(
            plan: plan, new_content: "ignored", base_revision: 1,
            actor_type: "local_agent", actor_id: user.id
          )
        rescue CoPlan::Plans::ReplaceContent::StaleRevisionError
          # expected
        end
      }.not_to change(CoPlan::PlanVersion, :count)
    end
  end

  describe "line ending normalization" do
    it "normalizes CRLF in new_content to LF before diffing" do
      # Stored content uses LF; agent submits CRLF (e.g. from Windows or a textarea).
      # Without normalization, every line would diff as changed and a single
      # wholesale-rewrite op would destroy all comment anchors.
      crlf_content = initial_content.gsub("\n", "\r\n")
      result = described_class.call(
        plan: plan, new_content: crlf_content, base_revision: 1,
        actor_type: "local_agent", actor_id: user.id
      )

      # Pure line-ending difference: should be detected as no-op since the
      # normalized content matches the stored LF content exactly.
      expect(result[:no_op]).to be true
      expect(result[:version]).to be_nil
    end

    it "normalizes CRLF and only emits ops for actual content changes" do
      crlf_with_one_change = initial_content
        .sub("unit tests", "integration tests")
        .gsub("\n", "\r\n")

      result = described_class.call(
        plan: plan, new_content: crlf_with_one_change, base_revision: 1,
        actor_type: "local_agent", actor_id: user.id
      )

      # Only the unit→integration change should produce an op, not every line.
      expect(result[:no_op]).to be false
      expect(result[:applied]).to eq(1)
      expect(result[:version].content_markdown).not_to include("\r")
      expect(result[:version].content_markdown).to include("integration tests")
    end
  end

  describe "roundtrip safety" do
    it "raises RoundtripFailureError if ApplyOperations doesn't reproduce new_content" do
      # Force a failure by stubbing DiffToOperations to return ops that don't match.
      allow(CoPlan::Plans::DiffToOperations).to receive(:call).and_return([])

      new_content = initial_content + "\nappended\n"
      expect {
        described_class.call(
          plan: plan, new_content: new_content, base_revision: 1,
          actor_type: "local_agent", actor_id: user.id
        )
      }.to raise_error(CoPlan::Plans::ReplaceContent::RoundtripFailureError, /roundtrip failure/)

      expect(plan.reload.current_revision).to eq(1)
      expect(CoPlan::PlanVersion.where(plan: plan).count).to eq(1)
    end
  end

  describe "comment thread anchor preservation" do
    let!(:thread_before) do
      CoPlan::CommentThread.create!(
        plan: plan,
        plan_version: plan.current_plan_version,
        created_by_user: user,
        anchor_text: "My Plan",
        anchor_revision: 1,
        anchor_start: initial_content.index("My Plan"),
        anchor_end: initial_content.index("My Plan") + "My Plan".length,
        status: "todo"
      )
    end

    let!(:thread_inside_change) do
      CoPlan::CommentThread.create!(
        plan: plan,
        plan_version: plan.current_plan_version,
        created_by_user: user,
        anchor_text: "unit tests",
        anchor_revision: 1,
        anchor_start: initial_content.index("unit tests"),
        anchor_end: initial_content.index("unit tests") + "unit tests".length,
        status: "todo"
      )
    end

    let!(:thread_after_change) do
      CoPlan::CommentThread.create!(
        plan: plan,
        plan_version: plan.current_plan_version,
        created_by_user: user,
        anchor_text: "Q1 2026 delivery.",
        anchor_revision: 1,
        anchor_start: initial_content.index("Q1 2026 delivery."),
        anchor_end: initial_content.index("Q1 2026 delivery.") + "Q1 2026 delivery.".length,
        status: "todo"
      )
    end

    it "keeps anchors before the change intact" do
      new_content = initial_content.sub("unit tests", "integration tests with full coverage")
      described_class.call(
        plan: plan, new_content: new_content, base_revision: 1,
        actor_type: "local_agent", actor_id: user.id
      )

      thread_before.reload
      expect(thread_before.out_of_date).to be false
      expect(new_content[thread_before.anchor_start...thread_before.anchor_end]).to eq("My Plan")
    end

    it "marks anchors that overlap the change as out-of-date" do
      new_content = initial_content.sub("unit tests", "integration tests")
      described_class.call(
        plan: plan, new_content: new_content, base_revision: 1,
        actor_type: "local_agent", actor_id: user.id
      )

      thread_inside_change.reload
      expect(thread_inside_change.out_of_date).to be true
    end

    it "shifts anchors after the change by the delta" do
      new_content = initial_content.sub("unit tests", "integration tests with full coverage")
      described_class.call(
        plan: plan, new_content: new_content, base_revision: 1,
        actor_type: "local_agent", actor_id: user.id
      )

      thread_after_change.reload
      expect(thread_after_change.out_of_date).to be false
      expect(new_content[thread_after_change.anchor_start...thread_after_change.anchor_end]).to eq("Q1 2026 delivery.")
    end
  end
end
