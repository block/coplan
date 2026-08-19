require "rails_helper"

RSpec.describe "Api::V1::AgentEvents", type: :request do
  let(:hampton) { create(:coplan_user, :admin) }
  let(:agent_token) { create(:api_token, user: hampton, raw_token: "test-token-agent", agent_name: "Claude") }
  let(:agent_headers) { { "Authorization" => "Bearer test-token-agent" } }
  let(:other_token) { create(:api_token, user: hampton, raw_token: "test-token-other", agent_name: "Amp") }
  let(:other_headers) { { "Authorization" => "Bearer test-token-other" } }
  let(:plan) { create(:plan, :considering, created_by_user: hampton) }

  before do
    agent_token
    other_token
  end

  describe "agent sessions" do
    it "claims a session, drives states, and rejects bogus states" do
      post api_v1_plan_agent_session_path(plan), params: { agent_name: "Claude" }, headers: agent_headers, as: :json
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      # Claiming means "attached", not "working" — the pill must not
      # advertise activity that isn't happening.
      expect(body["state"]).to eq("watching")
      expect(body["agent_name"]).to eq("Claude")

      patch api_v1_plan_agent_session_path(plan), params: { state: "awaiting_input", detail: "asked about rollout" }, headers: agent_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["state"]).to eq("awaiting_input")

      patch api_v1_plan_agent_session_path(plan), params: { state: "stale" }, headers: agent_headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "falls back to the token's agent_name when none is passed" do
      post api_v1_plan_agent_session_path(plan), headers: agent_headers, as: :json
      expect(JSON.parse(response.body)["agent_name"]).to eq("Claude")
    end

    it "can claim straight into a working state when the caller means it" do
      post api_v1_plan_agent_session_path(plan), params: { state: "active", detail: "reading your comment" }, headers: agent_headers, as: :json

      body = JSON.parse(response.body)
      expect(body["state"]).to eq("active")
      expect(body["state_detail"]).to eq("reading your comment")
    end

    it "reads as presence rather than activity while watching" do
      post api_v1_plan_agent_session_path(plan), params: { agent_name: "Claude" }, headers: agent_headers, as: :json

      session = CoPlan::AgentSession.find_by(plan_id: plan.id, api_token_id: agent_token.id)
      expect(session.display_status).to eq("Claude")
    end

    it "does not erase awaiting_input when the agent reattaches" do
      post api_v1_plan_agent_session_path(plan), headers: agent_headers, as: :json
      patch api_v1_plan_agent_session_path(plan), params: { state: "awaiting_input", detail: "asked about rollout" }, headers: agent_headers, as: :json

      post api_v1_plan_agent_session_path(plan), headers: agent_headers, as: :json

      body = JSON.parse(response.body)
      expect(body["state"]).to eq("awaiting_input")
      expect(body["state_detail"]).to eq("asked about rollout")
    end

    it "moves a watching session to pending when an event arrives" do
      post api_v1_plan_agent_session_path(plan), headers: agent_headers, as: :json
      session = CoPlan::AgentSession.find_by(plan_id: plan.id, api_token_id: agent_token.id)

      session.wake!

      expect(session.reload.state).to eq("pending")
    end

    it "is idempotent per (plan, token)" do
      2.times { post api_v1_plan_agent_session_path(plan), headers: agent_headers, as: :json }
      expect(CoPlan::AgentSession.where(plan_id: plan.id, api_token_id: agent_token.id).count).to eq(1)
    end
  end

  describe "event fan-out" do
    let!(:session) { create_agent_collab_session(agent_token) }
    let(:thread) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: hampton) }
    let(:comment) { create(:comment, comment_thread: thread, author_type: "human", author_id: hampton.id, body_markdown: "too formal!") }

    it "publishes comment events to subscribed agents and wakes the session" do
      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: hampton.id, comment: comment, reason: "new_comment")

      events = CoPlan::AgentEvent.for_token(agent_token)
      expect(events.count).to eq(1)
      event = events.first
      expect(event.event_type).to eq("comment.created")
      expect(event.payload["comment_body"]).to eq("too formal!")
      expect(event.payload["plan_title"]).to eq(plan.title)

      expect(session.reload.state).to eq("pending")
    end

    it "queues events for a detached session without giving it a pill" do
      session.update!(state: "complete", last_activity_at: 1.minute.ago)

      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: hampton.id, comment: comment, reason: "new_comment")

      # The inbox is durable — it gets the backlog when it reattaches...
      expect(CoPlan::AgentEvent.for_token(agent_token).count).to eq(1)
      # ...but an abandoned session must not be resurrected into a pill.
      expect(session.reload.state).to eq("complete")
      expect(CoPlan::AgentSession.visible).to be_empty
    end

    it "does not resurrect a session whose agent stopped responding" do
      session.update!(state: "pending", last_activity_at: 10.minutes.ago)

      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: hampton.id, comment: comment, reason: "new_comment")

      expect(CoPlan::AgentSession.visible).to be_empty
    end

    # Suppression keys on the comment's api_token_id (who *wrote* it), not
    # the notification actor_id — that holds the human, per the attribution
    # convention, and user ids must never be compared against token ids.
    it "does not wake the agent for its own comments" do
      own_comment = create(:comment, comment_thread: thread, author_type: "local_agent",
        author_id: hampton.id, agent_name: "Claude", api_token_id: agent_token.id, body_markdown: "my own reply")
      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: hampton.id, comment: own_comment, reason: "agent_response")

      expect(CoPlan::AgentEvent.for_token(agent_token).count).to eq(0)
    end

    it "types the first comment on a thread as created even when an agent opened it" do
      agent_comment = create(:comment, comment_thread: thread, author_type: "local_agent", author_id: other_token.id, agent_name: "Sara", body_markdown: "opening a thread")
      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: other_token.id, comment: agent_comment, reason: "agent_response")

      expect(CoPlan::AgentEvent.for_token(agent_token).first.event_type).to eq("comment.created")
    end

    it "types a later comment as replied regardless of author" do
      create(:comment, comment_thread: thread, author_type: "human", author_id: hampton.id, body_markdown: "first")
      second = create(:comment, comment_thread: thread, author_type: "human", author_id: hampton.id, body_markdown: "second")
      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: hampton.id, comment: second, reason: "new_comment")

      expect(CoPlan::AgentEvent.for_token(agent_token).first.event_type).to eq("comment.replied")
    end

    describe "authority" do
      it "marks a comment from the token's own human as principal" do
        CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: hampton.id, comment: comment, reason: "new_comment")

        payload = CoPlan::AgentEvent.for_token(agent_token).first.payload
        expect(payload["authority"]).to eq("principal")
        expect(payload["from_principal"]).to be(true)
        expect(payload["from_plan_author"]).to be(true)
      end

      it "marks a comment from anyone else as a collaborator" do
        sara = create(:coplan_user)
        sara_comment = create(:comment, comment_thread: thread, author_type: "human", author_id: sara.id, body_markdown: "drive-by thought")
        CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: sara.id, comment: sara_comment, reason: "new_comment")

        payload = CoPlan::AgentEvent.for_token(agent_token).first.payload
        expect(payload["authority"]).to eq("collaborator")
        expect(payload["from_principal"]).to be(false)
        expect(payload["from_plan_author"]).to be(false)
      end

      # The two questions come apart: an agent can be attached to a plan
      # somebody else wrote, and its own principal still outranks the author.
      it "separates 'my human' from 'the plan's author'" do
        sara = create(:coplan_user)
        sara_plan = create(:plan, :considering, created_by_user: sara)
        create_agent_collab_session(agent_token, plan: sara_plan)
        sara_thread = create(:comment_thread, plan: sara_plan, plan_version: sara_plan.current_plan_version, created_by_user: sara)
        hampton_comment = create(:comment, comment_thread: sara_thread, author_type: "human", author_id: hampton.id, body_markdown: "mine")
        CoPlan::Notifications::Create.call(comment_thread: sara_thread, actor_id: hampton.id, comment: hampton_comment, reason: "new_comment")

        payload = CoPlan::AgentEvent.for_token(agent_token).where(plan_id: sara_plan.id).first.payload
        expect(payload["from_principal"]).to be(true)
        expect(payload["from_plan_author"]).to be(false)
      end

      # An agent posting under a token carries that token's human, so a
      # second agent working for Hampton speaks with Hampton's authority.
      it "treats an agent comment as coming from the human behind its token" do
        agent_comment = create(:comment, comment_thread: thread, author_type: "local_agent", author_id: hampton.id, agent_name: "Amp", body_markdown: "from another agent")
        CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: other_token.id, comment: agent_comment, reason: "agent_response")

        payload = CoPlan::AgentEvent.for_token(agent_token).first.payload
        expect(payload["from_principal"]).to be(true)
      end
    end

    it "publishes content changes with changed section keys" do
      CoPlan::Plans::ReplaceContent.call(
        plan: plan,
        new_content: "# Title\n\nBrand new body.\n",
        base_revision: plan.current_revision,
        actor_type: "human",
        actor_id: hampton.id,
        change_summary: "Rewrite"
      )

      event = CoPlan::AgentEvent.for_token(agent_token).where(event_type: "plan.content_changed").first
      expect(event).to be_present
      expect(event.payload["changed_sections"]).to be_an(Array)
      expect(event.payload["change_summary"]).to eq("Rewrite")
    end
  end

  describe "GET /api/v1/agent/events" do
    let!(:session) { create_agent_collab_session(agent_token) }
    let!(:other_session) { create_agent_collab_session(other_token) }
    let(:thread) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: hampton) }

    before do
      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: hampton.id, body_markdown: "hello agents")
      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: hampton.id, comment: comment, reason: "new_comment")
    end

    it "returns pending events for the calling token only" do
      get api_v1_agent_events_path, params: { wait: 0 }, headers: agent_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["events"].length).to eq(1)
      expect(body["events"].first["type"]).to eq("comment.created")
      expect(body["cursor"]).to eq(body["events"].first["id"])
    end

    it "resumes from a cursor" do
      get api_v1_agent_events_path, params: { wait: 0 }, headers: agent_headers
      cursor = JSON.parse(response.body)["cursor"]

      get api_v1_agent_events_path, params: { wait: 0, cursor: cursor }, headers: agent_headers
      expect(JSON.parse(response.body)["events"]).to be_empty

      reply = create(:comment, comment_thread: thread, author_type: "human", author_id: hampton.id, body_markdown: "and another")
      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: hampton.id, comment: reply, reason: "reply")

      get api_v1_agent_events_path, params: { wait: 0, cursor: cursor }, headers: agent_headers
      events = JSON.parse(response.body)["events"]
      expect(events.length).to eq(1)
      expect(events.first["type"]).to eq("comment.replied")
    end

    # An attached agent holds a Rack thread for the life of its
    # connection. Over budget we answer immediately instead of letting
    # agents queue ahead of ordinary page requests.
    it "degrades long-poll to a non-blocking read when at the connection budget" do
      allow(CoPlan::AgentEventBus).to receive(:with_slot).and_yield(false)

      started = Time.current
      get api_v1_agent_events_path, params: { wait: 30 }, headers: agent_headers

      expect(Time.current - started).to be < 5
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["throttled"]).to be(true)
    end

    it "refuses a new stream over budget with Retry-After instead of blocking" do
      allow(CoPlan::AgentEventBus).to receive(:with_slot).and_yield(false)

      get api_v1_agent_events_path, headers: agent_headers.merge("Accept" => "text/event-stream")

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("5")
      expect(JSON.parse(response.body)["fallback"]).to include("long-poll")
    end

    it "signals waiters when an event is published" do
      allow(CoPlan::AgentEventBus).to receive(:signal)

      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: hampton.id, body_markdown: "wake up")
      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: hampton.id, comment: comment, reason: "reply")

      expect(CoPlan::AgentEventBus).to have_received(:signal).with(agent_token.id)
    end

    it "acks up to a cursor" do
      get api_v1_agent_events_path, params: { wait: 0 }, headers: agent_headers
      cursor = JSON.parse(response.body)["cursor"]

      post api_v1_agent_events_ack_path, params: { cursor: cursor }, headers: agent_headers, as: :json
      expect(JSON.parse(response.body)["acked"]).to eq(1)

      get api_v1_agent_events_path, params: { wait: 0 }, headers: agent_headers
      expect(JSON.parse(response.body)["events"]).to be_empty
    end
  end

  describe "agent attribution ergonomics" do
    # The token is the identity; the session is just presence on one plan.
    # Every write path (comments, versions, events) resolves the name the
    # same way — explicit param, then the token's agent_name, then its
    # name — so one agent can't sign comments "Ada" while its versions
    # say "Claude".
    it "attributes writes to the token's name even when the session was claimed under another label" do
      post api_v1_plan_agent_session_path(plan), params: { agent_name: "Ada" }, headers: agent_headers, as: :json

      post api_v1_plan_comments_path(plan), params: { body_markdown: "no name given" }, headers: agent_headers, as: :json

      expect(response).to have_http_status(:created)
      expect(CoPlan::Comment.last.agent_name).to eq("Claude")
    end

    it "falls back to the token's agent name when there is no session" do
      post api_v1_plan_comments_path(plan), params: { body_markdown: "no session either" }, headers: agent_headers, as: :json

      expect(response).to have_http_status(:created)
      expect(CoPlan::Comment.last.agent_name).to eq("Claude")
    end

    it "truncates an over-long name instead of losing the comment" do
      post api_v1_plan_comments_path(plan),
        params: { body_markdown: "hi", agent_name: "Claude (this session, attached)" },
        headers: agent_headers, as: :json

      expect(response).to have_http_status(:created)
      expect(CoPlan::Comment.last.agent_name.length).to eq(CoPlan::Comment::AGENT_NAME_LIMIT)
    end

    it "returns id alongside comment_id so creates match the rest of the API" do
      post api_v1_plan_comments_path(plan), params: { body_markdown: "first" }, headers: agent_headers, as: :json
      thread_id = JSON.parse(response.body)["thread_id"]

      post reply_api_v1_plan_comment_path(plan, thread_id), params: { body_markdown: "second" }, headers: agent_headers, as: :json

      body = JSON.parse(response.body)
      expect(body["id"]).to eq(body["comment_id"])
      expect(body["id"]).to be_present
    end

    it "lets a comment be destroyed without tripping the notification foreign key" do
      thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: hampton)
      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: hampton.id, body_markdown: "doomed")
      CoPlan::Notification.create!(user_id: hampton.id, plan_id: plan.id, comment_thread_id: thread.id, comment_id: comment.id, reason: "new_comment")

      expect { comment.destroy! }.to change(CoPlan::Notification, :count).by(-1)
    end
  end

  describe "comment API ergonomics" do
    let(:thread) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: hampton) }

    before { create(:comment, comment_thread: thread, author_type: "human", author_id: hampton.id, body_markdown: "first") }

    it "fetches a single thread" do
      get api_v1_plan_comment_path(plan, thread), headers: agent_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["id"]).to eq(thread.id)
      expect(body["comments"].length).to eq(1)
    end

    it "accepts dismiss as an alias for discard" do
      patch dismiss_api_v1_plan_comment_path(plan, thread), headers: agent_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(thread.reload.status).to eq("discarded")
    end

    it "does not leave an orphan thread when the first comment fails validation" do
      expect {
        # An empty body fails the comment, which must roll the thread back
        # too — otherwise the plan keeps an empty thread with a live anchor.
        post api_v1_plan_comments_path(plan), params: { body_markdown: "" }, headers: agent_headers, as: :json
      }.not_to change(CoPlan::CommentThread, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "gives the plan author's own API threads the todo initial status" do
      post api_v1_plan_comments_path(plan), params: { body_markdown: "note to self", agent_name: "Claude" }, headers: agent_headers, as: :json
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["status"]).to eq("todo")
    end
  end

  # An agent that has claimed a session and is attached, which is the
  # state fan-out actually cares about.
  def create_agent_collab_session(token, plan: self.plan)
    CoPlan::AgentSession.create!(
      plan_id: plan.id,
      api_token_id: token.id,
      agent_name: token.agent_name,
      state: "watching",
      last_activity_at: Time.current
    )
  end
end
