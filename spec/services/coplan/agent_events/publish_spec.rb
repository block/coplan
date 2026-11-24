require "rails_helper"

RSpec.describe Coplan::AgentEvents::Publish do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:watcher_token) { create(:api_token, user: user, agent_name: "Amp") }
  let(:recipient_token) { create(:api_token, user: user, agent_name: "Claude") }

  before do
    Coplan::AgentSession.create!(plan: plan, api_token: watcher_token, state: "watching", agent_name: "Amp")
  end

  def publish(**options)
    described_class.call(plan: plan, event_type: "session.commit_failed", payload: { "reason" => "conflict" }, **options)
  end

  describe "with a comment" do
    let(:thread) { create(:comment_thread, plan: plan, created_by_user: user) }
    let(:comment) { create(:comment, comment_thread: thread, author_type: "human", author_id: user.id, body_markdown: "Wrong plan, ignore") }

    def publish_comment(loaded)
      described_class.call(plan: plan, event_type: "comment.created", comment_thread: thread, comment: loaded, payload: {})
    end

    it "queues the comment's body" do
      publish_comment(comment)
      expect(Coplan::AgentEvent.sole.payload["comment_body"]).to eq("Wrong plan, ignore")
    end

    it "queues nothing when the comment was deleted after the caller loaded it" do
      loaded = Coplan::Comment.find(comment.id)
      Coplan::Comments::SoftDelete.call(comment: comment, actor: user)

      expect { publish_comment(loaded) }.not_to change(Coplan::AgentEvent, :count)
    end

    it "keeps every queued event when waking a session fails" do
      second = create(:api_token, user: user, agent_name: "Claude")
      [ watcher_token, second ].each do |token|
        Coplan::AgentSession.find_or_create_by!(plan: plan, api_token: token) { |s| s.state = "watching"; s.agent_name = token.agent_name }
          .update!(wake_url: "https://agents.example.com/hooks/wake", wake_secret: "s3cret")
      end
      allow(Coplan::WakeWebhookJob).to receive(:perform_later)
      allow(Coplan::AgentEventBus).to receive(:signal)
      allow(Rails.error).to receive(:report)
      allow_any_instance_of(Coplan::AgentSession).to receive(:broadcast_pill).and_raise(RuntimeError, "cable down")

      expect { publish_comment(comment) }.not_to raise_error
      events = Coplan::AgentEvent.where(comment_id: comment.id)
      expect(events.pluck(:api_token_id)).to contain_exactly(watcher_token.id, second.id)
      events.each do |event|
        session = Coplan::AgentSession.find_by!(plan: plan, api_token_id: event.api_token_id)
        expect(Coplan::WakeWebhookJob).to have_received(:perform_later)
          .with(agent_session_id: session.id, agent_event_id: event.id).once
        expect(Coplan::AgentEventBus).to have_received(:signal).with(event.api_token_id).once
      end
      expect(Rails.error).to have_received(:report).with(instance_of(RuntimeError)).twice
    end
  end

  describe "committed delivery" do
    self.use_transactional_tests = false
    after { truncate_tables(*(ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata])) }

    let(:session) { Coplan::AgentSession.find_by!(plan: plan, api_token: watcher_token) }

    before do
      session.update!(wake_url: "https://agents.example.com/hooks/wake", wake_secret: "secret")
      allow(Coplan::WakeWebhookJob).to receive(:perform_later)
      allow(Coplan::AgentEventBus).to receive(:signal)
    end

    it "defers all wake effects until the outer transaction commits" do
      Coplan::AgentEvent.transaction do
        Coplan::AgentEvent.transaction(requires_new: true) { publish }
        expect(session.reload.state).to eq("watching")
        expect(Coplan::WakeWebhookJob).not_to have_received(:perform_later)
        expect(Coplan::AgentEventBus).not_to have_received(:signal)
        expect(Thread.new { ActiveRecord::Base.connection_pool.with_connection { Coplan::AgentEvent.count } }.value).to eq(0)
      end

      expect(Thread.new { ActiveRecord::Base.connection_pool.with_connection { Coplan::AgentEvent.count } }.value).to eq(1)
      expect(session.reload.state).to eq("pending")
      expect(Coplan::WakeWebhookJob).to have_received(:perform_later).once
      expect(Coplan::AgentEventBus).to have_received(:signal).with(watcher_token.id).once
    end

    it "discards all wake effects when the outer transaction rolls back" do
      Coplan::AgentEvent.transaction do
        Coplan::AgentEvent.transaction(requires_new: true) { publish }
        raise ActiveRecord::Rollback
      end

      expect(Coplan::AgentEvent.count).to eq(0)
      expect(session.reload.state).to eq("watching")
      expect(Coplan::WakeWebhookJob).not_to have_received(:perform_later)
      expect(Coplan::AgentEventBus).not_to have_received(:signal)
    end

    it "keeps every recipient committed and signaled when a wake fails" do
      second = create(:api_token, user: user, agent_name: "Claude")
      Coplan::AgentSession.create!(plan: plan, api_token: second, state: "watching", agent_name: "Claude",
        wake_url: "https://agents.example.com/hooks/wake", wake_secret: "secret")
      thread = create(:comment_thread, plan: plan, created_by_user: user)
      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: user.id)
      allow(Rails.error).to receive(:report)
      visible_counts = []
      allow_any_instance_of(Coplan::AgentSession).to receive(:broadcast_pill) do
        visible_counts << Thread.new {
          ActiveRecord::Base.connection_pool.with_connection { Coplan::AgentEvent.count }
        }.value
        raise "cable down"
      end

      expect {
        described_class.call(plan: plan, event_type: "comment.created", comment_thread: thread, comment: comment)
      }.not_to raise_error

      expect(visible_counts).to eq([ 2, 2 ])
      expect(Coplan::AgentEvent.pluck(:api_token_id)).to contain_exactly(watcher_token.id, second.id)
      expect(Coplan::WakeWebhookJob).to have_received(:perform_later).twice
      [ watcher_token, second ].each do |token|
        expect(Coplan::AgentEventBus).to have_received(:signal).with(token.id).once
      end
    end

    %w[active awaiting_input].each do |state|
      it "preserves an #{state} response committed before the deferred wake" do
        Coplan::AgentEvent.transaction do
          ActiveRecord.after_all_transactions_commit do
            # A polling agent can see the event as soon as the commit completes.
            session.transition!(state, detail: "reviewing")
          end
          publish
        end

        expect(session.reload).to have_attributes(state: state, state_detail: "reviewing")
        expect(Coplan::AgentEvent.count).to eq(1)
        expect(Coplan::WakeWebhookJob).to have_received(:perform_later).once
        expect(Coplan::AgentEventBus).to have_received(:signal).with(watcher_token.id).once
      end
    end

    it "still wakes an agent whose question predates the event" do
      session.transition!("awaiting_input", detail: "Which option?")

      publish

      expect(session.reload).to have_attributes(state: "pending", state_detail: nil)
      expect(Coplan::WakeWebhookJob).to have_received(:perform_later).once
      expect(Coplan::AgentEventBus).to have_received(:signal).with(watcher_token.id).once
    end
  end

  describe "with recipient_token_id" do
    it "delivers to a token with no session on the plan, and to no one else" do
      allow(Coplan::AgentEventBus).to receive(:signal)

      expect { publish(recipient_token_id: recipient_token.id) }
        .to change { Coplan::AgentEvent.count }.by(1)

      event = Coplan::AgentEvent.sole
      expect(event.api_token_id).to eq(recipient_token.id)
      expect(event.payload).to include("plan_title" => plan.title, "reason" => "conflict")
      expect(Coplan::AgentEventBus).to have_received(:signal).with(recipient_token.id).once
      expect(Coplan::AgentEventBus).not_to have_received(:signal).with(watcher_token.id)
    end

    it "wakes the recipient's own session on the plan" do
      allow(Coplan::WakeWebhookJob).to receive(:perform_later)
      session = Coplan::AgentSession.create!(
        plan: plan, api_token: recipient_token, state: "complete", agent_name: "Claude",
        wake_url: "https://agents.example.com/hooks/wake", wake_secret: "s3cret"
      )

      publish(recipient_token_id: recipient_token.id)

      event = Coplan::AgentEvent.sole
      expect(event.api_token_id).to eq(recipient_token.id)
      expect(Coplan::WakeWebhookJob).to have_received(:perform_later)
        .with(agent_session_id: session.id, agent_event_id: event.id).once
    end

    it "skips a revoked token" do
      recipient_token.update!(revoked_at: 1.minute.ago)

      expect { publish(recipient_token_id: recipient_token.id) }
        .not_to change { Coplan::AgentEvent.count }
    end

    it "skips an expired token" do
      recipient_token.update!(expires_at: 1.minute.ago)

      expect { publish(recipient_token_id: recipient_token.id) }
        .not_to change { Coplan::AgentEvent.count }
    end

    it "skips a child whose parent has expired" do
      parent = create(:api_token, user: user, expires_at: 1.minute.ago)
      recipient_token.update!(parent: parent)
      expect { publish(recipient_token_id: recipient_token.id) }.not_to change(Coplan::AgentEvent, :count)
    end

    it "does not fan out a blank recipient" do
      expect { publish(recipient_token_id: "") }.not_to change(Coplan::AgentEvent, :count)
    end

    it "does not signal or enqueue a wake for a rolled-back event" do
      allow(Coplan::AgentEventBus).to receive(:signal)
      allow(Coplan::WakeWebhookJob).to receive(:perform_later)
      Coplan::AgentSession.create!(plan: plan, api_token: recipient_token, state: "complete",
        agent_name: "Claude", wake_url: "https://agents.example.com/wake", wake_secret: "secret")
      Coplan::AgentEvent.transaction(requires_new: true) do
        publish(recipient_token_id: recipient_token.id)
        expect(Coplan::AgentEventBus).not_to have_received(:signal)
        expect(Coplan::WakeWebhookJob).not_to have_received(:perform_later)
        raise ActiveRecord::Rollback
      end
      expect(Coplan::AgentEvent.count).to eq(0)
      expect(Coplan::AgentEventBus).not_to have_received(:signal)
      expect(Coplan::WakeWebhookJob).not_to have_received(:perform_later)
    end

    it "skips an id that names no token" do
      expect { publish(recipient_token_id: user.id) }
        .not_to change { Coplan::AgentEvent.count }
    end
  end

  describe "without recipient_token_id" do
    it "fans out to every session on the plan except the actor's" do
      Coplan::AgentSession.create!(plan: plan, api_token: recipient_token, state: "watching", agent_name: "Claude")

      publish(actor_token_id: recipient_token.id)

      expect(Coplan::AgentEvent.pluck(:api_token_id)).to eq([ watcher_token.id ])
    end
  end
end
