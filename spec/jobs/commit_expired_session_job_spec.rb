require "rails_helper"

RSpec.describe CoPlan::CommitExpiredSessionJob do
  include ActiveJob::TestHelper
  let(:user) { create(:coplan_user) }
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
        operations_json: [ { "op" => "replace_exact", "old_text" => "Some content", "new_text" => "Updated content", "resolved_range" => [ 16, 28 ], "new_range" => [ 16, 32 ], "delta" => 4 } ],
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
        operations_json: [ { "op" => "replace_exact", "old_text" => "Some content", "new_text" => "Changed", "resolved_range" => [ 16, 28 ], "new_range" => [ 16, 23 ], "delta" => -5 } ],
        draft_content: "# Test Plan\n\nChanged here."
      )

      # Make an intervening edit that changes the same text
      new_content = "# Test Plan\n\nDifferent content here."
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human",
        actor_id: user.id,
        operations_json: [ { "op" => "replace_exact", "resolved_range" => [ 16, 28 ], "new_range" => [ 16, 35 ], "delta" => 7 } ]
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

    describe "telling the owner the auto-commit failed" do
      let(:owner_token) { create(:api_token, user: user, agent_name: "Claude") }
      let(:watcher_token) { create(:api_token, user: user, agent_name: "Amp") }
      let(:session) do
        CoPlan::EditSession.create!(
          plan: plan, actor_type: "local_agent", actor_id: owner_token.id,
          base_revision: 1, expires_at: 1.minute.ago,
          operations_json: [ { "op" => "replace_exact", "old_text" => "Some content", "new_text" => "Changed", "resolved_range" => [ 16, 28 ], "new_range" => [ 16, 23 ], "delta" => -5 } ],
          draft_content: "# Test Plan\n\nChanged here."
        )
      end

      before do
        # Another agent watches the plan; it must not hear about a session
        # that wasn't its own.
        CoPlan::AgentSession.create!(plan: plan, api_token: watcher_token, state: "watching", agent_name: "Amp")
      end

      # The owner has read the human's revision 1, so the human-edit fence
      # lets the commit through to the rebase, where another agent's edit to
      # the same text conflicts.
      def conflicting_agent_edit
        CoPlan::PlanRead.record!(plan: plan, reader_type: "api_token", reader_id: owner_token.id, revision: 1)
        version2 = CoPlan::PlanVersion.create!(
          plan: plan, revision: 2,
          content_markdown: "# Test Plan\n\nDifferent content here.", actor_type: "local_agent",
          actor_id: user.id,
          operations_json: [ { "op" => "replace_exact", "resolved_range" => [ 16, 28 ], "new_range" => [ 16, 35 ], "delta" => 7 } ]
        )
        plan.update!(current_plan_version: version2, current_revision: 2)
      end

      it "publishes one session.commit_failed event to the owner's token only" do
        session
        conflicting_agent_edit

        expect { described_class.new.perform(session_id: session.id) }
          .to change { CoPlan::AgentEvent.count }.by(1)

        expect(session.reload.status).to eq("failed")
        event = CoPlan::AgentEvent.sole
        expect(event.api_token_id).to eq(owner_token.id)
        expect(event.event_type).to eq("session.commit_failed")
        expect(event.plan_id).to eq(plan.id)
        expect(event.payload).to include(
          "session_id" => session.id,
          "base_revision" => 1,
          "current_revision" => 2,
          "reason" => "conflict"
        )
        expect(event.payload["message"]).to include("Conflict")
        expect(event.payload).not_to have_key("expected")
        expect(event.payload).not_to have_key("found")
      end

      it "does not repeat the event when the job is retried" do
        session
        2.times { described_class.new.perform(session_id: session.id) }
        expect(CoPlan::AgentEvent.count).to eq(1)
      end

      it "keeps the session retryable when inbox creation fails" do
        session
        allow(CoPlan::AgentEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "inbox unavailable")
        clear_enqueued_jobs
        expect { described_class.perform_now(session_id: session.id) }
          .to have_enqueued_job(described_class).with(session_id: session.id)
        expect(session.reload.status).to eq("open")
        expect(CoPlan::AgentEvent.count).to eq(0)

        allow(CoPlan::AgentEvent).to receive(:create!).and_call_original
        perform_enqueued_jobs
        expect(session.reload.status).to eq("failed")
        expect(CoPlan::AgentEvent.count).to eq(1)
      end

      it "does not overwrite a session closed between the conflict and failure handling" do
        session
        allow(CoPlan::Plans::CommitSession).to receive(:call) do
          CoPlan::EditSession.find(session.id).update!(status: "committed")
          raise CoPlan::Plans::CommitSession::SessionConflictError, "conflict"
        end
        expect { described_class.new.perform(session_id: session.id) }.not_to change(CoPlan::AgentEvent, :count)
        expect(session.reload.status).to eq("committed")
      end

      it "does not broadcast an ownerless failure to watchers" do
        session.update!(actor_id: nil)
        allow(CoPlan::Plans::CommitSession).to receive(:call).and_raise(CoPlan::Plans::CommitSession::SessionConflictError, "conflict")
        expect { described_class.new.perform(session_id: session.id) }.not_to change(CoPlan::AgentEvent, :count)
        expect(session.reload.status).to eq("failed")
      end

      it "reports stale sessions separately from conflicts" do
        session
        conflicting_agent_edit
        plan.update!(current_revision: 22)
        described_class.new.perform(session_id: session.id)
        expect(CoPlan::AgentEvent.sole.payload).to include("reason" => "stale")
      end

      it "still fails the session but publishes nothing when the owner's token is revoked" do
        session
        conflicting_agent_edit
        owner_token.update!(revoked_at: 1.minute.ago)

        expect { described_class.new.perform(session_id: session.id) }
          .not_to change { CoPlan::AgentEvent.count }

        expect(session.reload.status).to eq("failed")
      end

      it "publishes with reason human_edit_pending when an unread human edit blocks the commit" do
        session
        # No PlanRead for the owner: the human's revision 1 is unread.

        expect { described_class.new.perform(session_id: session.id) }
          .not_to change { plan.reload.current_revision }

        expect(session.reload.status).to eq("failed")
        expect(session.change_summary).to include("Auto-commit blocked")
        event = CoPlan::AgentEvent.sole
        expect(event.api_token_id).to eq(owner_token.id)
        expect(event.event_type).to eq("session.commit_failed")
        expect(event.payload).to include(
          "session_id" => session.id,
          "base_revision" => 1,
          "current_revision" => 1,
          "reason" => "human_edit_pending"
        )
        expect(event.payload["message"]).to be_present
      end
    end
  end
end
