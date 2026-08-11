require "rails_helper"

RSpec.describe "Api::V1::Tokens", type: :request do
  let(:hampton) { create(:coplan_user, :admin) }
  let(:parent_token) { create(:api_token, user: hampton, raw_token: "test-token-parent", agent_name: "Claude", name: "hampton-laptop") }
  let(:parent_headers) { { "Authorization" => "Bearer test-token-parent" } }

  before { parent_token }

  it "mints a session token usable for the rest of the API" do
    post api_v1_tokens_path, params: { agent_name: "Claude (refactor)" }, headers: parent_headers, as: :json

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["agent_name"]).to eq("Claude (refactor)")
    expect(body["parent_id"]).to eq(parent_token.id)
    expect(body["expires_at"]).to be_present

    plan = create(:plan, :considering, created_by_user: hampton)
    post api_v1_plan_agent_session_path(plan),
      headers: { "Authorization" => "Bearer #{body["token"]}" }, as: :json

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)["agent_name"]).to eq("Claude (refactor)")
  end

  it "gives each minted token its own event inbox" do
    post api_v1_tokens_path, params: { agent_name: "One" }, headers: parent_headers, as: :json
    first = JSON.parse(response.body)["token"]
    post api_v1_tokens_path, params: { agent_name: "Two" }, headers: parent_headers, as: :json
    second = JSON.parse(response.body)["token"]

    expect(first).not_to eq(second)

    plan = create(:plan, :considering, created_by_user: hampton)
    post api_v1_plan_agent_session_path(plan), headers: { "Authorization" => "Bearer #{first}" }, as: :json
    CoPlan::AgentEvents::Publish.call(plan: plan, event_type: "plan.content_changed")

    get api_v1_agent_events_path, headers: { "Authorization" => "Bearer #{first}" }, params: { wait: 0 }
    expect(JSON.parse(response.body)["events"].length).to eq(1)

    # The second token never attached to that plan, so its inbox is empty
    # — two agents on one machine don't steal each other's wakes.
    get api_v1_agent_events_path, headers: { "Authorization" => "Bearer #{second}" }, params: { wait: 0 }
    expect(JSON.parse(response.body)["events"]).to be_empty
  end

  it "refuses to mint from a session token" do
    post api_v1_tokens_path, headers: parent_headers, as: :json
    child = JSON.parse(response.body)["token"]

    post api_v1_tokens_path, headers: { "Authorization" => "Bearer #{child}" }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "clamps an absurd ttl instead of honouring it" do
    post api_v1_tokens_path, params: { ttl_seconds: 365.days.to_i }, headers: parent_headers, as: :json

    expires = Time.zone.parse(JSON.parse(response.body)["expires_at"])
    expect(expires).to be_within(1.minute).of(CoPlan::ApiToken::MAX_SESSION_TTL.from_now)
  end

  it "self-revokes so an agent can clean up on exit" do
    post api_v1_tokens_path, headers: parent_headers, as: :json
    child = JSON.parse(response.body)["token"]
    child_headers = { "Authorization" => "Bearer #{child}" }

    delete api_v1_revoke_current_token_path, headers: child_headers, as: :json
    expect(response).to have_http_status(:ok)

    delete api_v1_revoke_current_token_path, headers: child_headers, as: :json
    expect(response).to have_http_status(:unauthorized)

    # Revoking a child leaves the parent alone.
    expect(parent_token.reload).not_to be_revoked
  end

  it "requires token auth" do
    post api_v1_tokens_path, as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
