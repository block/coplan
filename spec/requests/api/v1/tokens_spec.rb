require "rails_helper"

RSpec.describe "Api::V1::Tokens", type: :request do
  let(:alice) { create(:coplan_user, :admin, name: "Alice") }
  let(:root_token) { create(:api_token, user: alice, name: "alice-laptop", agent_name: "Claude", raw_token: "test-root-alice") }
  let(:root_headers) { { "Authorization" => "Bearer test-root-alice" } }

  before { root_token }

  def hook_auth_as(user)
    allow(CoPlan.configuration).to receive(:api_authenticate)
      .and_return(->(_req) { { external_id: user.external_id } })
  end

  describe "POST /api/v1/tokens" do
    it "mints a session child from a root token" do
      post api_v1_tokens_path,
        params: { agent_name: "Claude run", ttl_seconds: 3600 },
        headers: root_headers, as: :json

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["token"]).to be_present
      expect(body["agent_name"]).to eq("Claude run")
      expect(body["parent_id"]).to eq(root_token.id)

      minted = CoPlan::ApiToken.authenticate(body["token"])
      expect(minted.user_id).to eq(alice.id)
      expect(minted.expires_at).to be_within(1.minute).of(1.hour.from_now)
    end

    # The bootstrap: in production the proxy authenticates every request as
    # the human, and this is the one call that accepts that alone — it is
    # how an agent gets the Bearer token everything else requires.
    it "mints a session token from hook auth alone" do
      hook_auth_as(alice)

      post api_v1_tokens_path, params: { agent_name: "Claude" }, as: :json

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["parent_id"]).to be_nil
      minted = CoPlan::ApiToken.authenticate(body["token"])
      expect(minted.user_id).to eq(alice.id)
      expect(minted.expires_at).to be_present
    end

    it "refuses a session token as the minting credential" do
      child, raw = root_token.mint_session_token!

      post api_v1_tokens_path, headers: { "Authorization" => "Bearer #{raw}" }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to include("parent token")
      expect(child.children).to be_empty
    end

    it "requires some authentication" do
      post api_v1_tokens_path, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /api/v1/tokens/current" do
    it "revokes the token that authenticated the request" do
      child, raw = root_token.mint_session_token!

      delete api_v1_revoke_current_token_path, headers: { "Authorization" => "Bearer #{raw}" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(child.reload).to be_revoked
      expect(root_token.reload).not_to be_revoked
    end

    it "is not available on hook auth — there is no token to revoke" do
      hook_auth_as(alice)

      delete api_v1_revoke_current_token_path, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "the Bearer requirement everywhere else" do
    let(:plan) { create(:plan, :considering, created_by_user: alice) }

    it "rejects hook-authenticated API calls, pointing at the mint" do
      hook_auth_as(alice)

      get api_v1_plans_path, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to include("POST", "tokens")
    end

    it "rejects hook-authenticated writes — they would be misattributed as human" do
      hook_auth_as(alice)

      put api_v1_plan_content_path(plan),
        params: { content: "# Sneaky\n", base_revision: plan.current_revision },
        as: :json

      expect(response).to have_http_status(:forbidden)
      expect(plan.reload.current_revision).to eq(1)
    end

    it "still returns 401 when nothing authenticates at all" do
      get api_v1_plans_path, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
