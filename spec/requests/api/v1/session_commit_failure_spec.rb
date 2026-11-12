require "rails_helper"

RSpec.describe "Expired edit session recovery", type: :request do
  it "delivers only to the owning credential and requires a fresh read before recovery" do
    user = create(:coplan_user)
    token = create(:api_token, user: user, raw_token: "recovery-owner", agent_name: "Recovery")
    sibling = create(:api_token, user: user, raw_token: "recovery-sibling")
    stranger = create(:api_token, raw_token: "recovery-stranger")
    plan = create(:plan, created_by_user: user)
    headers = { "Authorization" => "Bearer recovery-owner" }
    [ sibling, stranger ].each do |watcher|
      CoPlan::AgentSession.create!(plan: plan, api_token: watcher, agent_name: "Watcher", state: "watching")
    end

    get api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:ok)
    post api_v1_plan_sessions_path(plan), headers: headers, as: :json
    expect(response).to have_http_status(:created)
    session = CoPlan::EditSession.find(JSON.parse(response.body).fetch("id"))
    expect(session.actor_id).to eq(token.id)
    post api_v1_plan_operations_path(plan), headers: headers, as: :json, params: {
      session_id: session.id, base_revision: 1,
      operations: [ { op: "replace_exact", old_text: "Some content here.", new_text: "Agent draft.", count: 1 } ]
    }
    expect(response).to have_http_status(:created)

    human = CoPlan::PlanVersion.create!(plan: plan, revision: 2,
      content_markdown: "# Test Plan\n\nHuman decision.\n", actor_type: "human", actor_id: user.id)
    plan.update!(current_plan_version: human, current_revision: 2)
    CoPlan::CommitExpiredSessionJob.perform_now(session_id: session.id)
    CoPlan::CommitExpiredSessionJob.perform_now(session_id: session.id)
    expect(session.reload.status).to eq("failed")
    expect(plan.reload.current_revision).to eq(2)

    get api_v1_agent_events_path, headers: headers
    event = JSON.parse(response.body).fetch("events").sole
    expect(event).to include("type" => "session.commit_failed", "comment_thread_id" => nil)
    expect(event.fetch("payload")).to include("reason" => "human_edit_pending", "session_id" => session.id)
    %w[recovery-sibling recovery-stranger].each do |other|
      get api_v1_agent_events_path, headers: { "Authorization" => "Bearer #{other}" }
      expect(JSON.parse(response.body).fetch("events")).to be_empty
      get api_v1_plan_session_path(plan, session), headers: { "Authorization" => "Bearer #{other}" }
      expect(response).to have_http_status(:not_found)
    end

    post api_v1_plan_sessions_path(plan), headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body).fetch("code")).to eq("human_edit_pending")
    get api_v1_plan_path(plan), headers: headers
    expect(JSON.parse(response.body).fetch("current_content")).to include("Human decision.")
    post commit_api_v1_plan_session_path(plan, session), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)

    post api_v1_plan_sessions_path(plan), headers: headers, as: :json
    fresh_id = JSON.parse(response.body).fetch("id")
    post api_v1_plan_operations_path(plan), headers: headers, as: :json, params: {
      session_id: fresh_id, base_revision: 2,
      operations: [ { op: "replace_exact", old_text: "Human decision.", new_text: "Human decision. Agent clarification.", count: 1 } ]
    }
    expect(response).to have_http_status(:created)
    post commit_api_v1_plan_session_path(plan, fresh_id), headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(plan.reload.current_revision).to eq(3)
    expect(plan.current_content).to include("Human decision. Agent clarification.")
    expect(plan.current_plan_version).to have_attributes(api_token_id: token.id, actor_id: user.id, agent_name: "Recovery")
  end
end
