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
      expect(body["state"]).to eq("active")
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

    it "does not wake the agent for its own comments" do
      CoPlan::Notifications::Create.call(comment_thread: thread, actor_id: agent_token.id, comment: comment, reason: "agent_response")

      expect(CoPlan::AgentEvent.for_token(agent_token).count).to eq(0)
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

    it "acks up to a cursor" do
      get api_v1_agent_events_path, params: { wait: 0 }, headers: agent_headers
      cursor = JSON.parse(response.body)["cursor"]

      post api_v1_agent_events_ack_path, params: { cursor: cursor }, headers: agent_headers, as: :json
      expect(JSON.parse(response.body)["acked"]).to eq(1)

      get api_v1_agent_events_path, params: { wait: 0 }, headers: agent_headers
      expect(JSON.parse(response.body)["events"]).to be_empty
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
        # local_agent comments require agent_name — omitting it fails the
        # comment, which must roll the thread back too.
        post api_v1_plan_comments_path(plan), params: { body_markdown: "no agent name" }, headers: agent_headers, as: :json
      }.not_to change(CoPlan::CommentThread, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "gives the plan author's own API threads the todo initial status" do
      post api_v1_plan_comments_path(plan), params: { body_markdown: "note to self", agent_name: "Claude" }, headers: agent_headers, as: :json
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["status"]).to eq("todo")
    end
  end

  def create_agent_collab_session(token)
    CoPlan::AgentSession.create!(
      plan_id: plan.id,
      api_token_id: token.id,
      agent_name: token.agent_name,
      state: "complete"
    )
  end
end
