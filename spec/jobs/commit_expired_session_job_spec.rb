require "rails_helper"

RSpec.describe CoPlan::CommitExpiredSessionJob do
  let(:org) { create(:organization) }
  let(:user) { create(:user, organization: org) }
  let(:content) { "# Test Plan\n\nSome content here." }
  let(:plan) do
    plan = CoPlan::Plan.create!(title: "Test Plan", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: plan, revision: 1,
      content_markdown: content, actor_type: "human", actor_id: user.id
    )
    plan.update!(current_plan_version: version, current_revision: 1)
    plan
  end

  describe "#perform" do
    it "auto-commits session with operations" do
      session = CoPlan::EditSession.create!(
        plan: plan, actor_type: "local_agent",
        base_revision: 1, expires_at: 1.minute.ago,
        operations_json: [{"op" => "replace_exact", "old_text" => "Some content", "new_text" => "Updated content", "resolved_range" => [16, 28], "new_range" => [16, 32], "delta" => 4}],
        draft_content: "# Test Plan\n\nUpdated content here."
      )

      expect { described_class.new.perform(session_id: session.id) }
        .to change { CoPlan::PlanVersion.count }.by(1)

      session.reload
      expect(session.status).to eq("committed")
      expect(session.committed_at).to be_present
    end

    it "marks empty session as expired" do
      session = CoPlan::EditSession.create!(
        plan: plan, actor_type: "local_agent",
        base_revision: 1, expires_at: 1.minute.ago
      )

      expect { described_class.new.perform(session_id: session.id) }
        .not_to change { CoPlan::PlanVersion.count }

      session.reload
      expect(session.status).to eq("expired")
    end

    it "skips already committed sessions" do
      session = CoPlan::EditSession.create!(
        plan: plan, actor_type: "local_agent",
        base_revision: 1, expires_at: 1.minute.ago,
        status: "committed", committed_at: 2.minutes.ago
      )

      expect { described_class.new.perform(session_id: session.id) }
        .not_to change { CoPlan::PlanVersion.count }
    end

    it "skips deleted sessions" do
      expect { described_class.new.perform(session_id: "nonexistent-id") }
        .not_to raise_error
    end

    it "marks session as failed on conflict" do
      # Create a plan, open a session, then make an intervening edit that conflicts
      session = CoPlan::EditSession.create!(
        plan: plan, actor_type: "local_agent",
        base_revision: 1, expires_at: 1.minute.ago,
        operations_json: [{"op" => "replace_exact", "old_text" => "Some content", "new_text" => "Changed", "resolved_range" => [16, 28], "new_range" => [16, 23], "delta" => -5}],
        draft_content: "# Test Plan\n\nChanged here."
      )

      # Make an intervening edit that changes the same text
      new_content = "# Test Plan\n\nDifferent content here."
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human",
        actor_id: user.id,
        operations_json: [{"op" => "replace_exact", "resolved_range" => [16, 28], "new_range" => [16, 35], "delta" => 7}]
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      expect { described_class.new.perform(session_id: session.id) }
        .not_to change { plan.reload.current_revision }

      session.reload
      expect(session.status).to eq("failed")
      expect(session.change_summary).to include("Auto-commit failed")
    end

    it "is enqueued when EditSession is created" do
      expect {
        CoPlan::EditSession.create!(
          plan: plan, actor_type: "local_agent",
          base_revision: 1, expires_at: 10.minutes.from_now
        )
      }.to have_enqueued_job(CoPlan::CommitExpiredSessionJob)
    end
  end
end
