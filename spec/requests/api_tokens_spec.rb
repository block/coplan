require "rails_helper"

RSpec.describe "ApiTokens", type: :request do
  let(:org) { create(:organization) }
  let(:alice) { create(:user, :admin, organization: org) }

  before { sign_in_as(alice) }

  it "index shows tokens" do
    create(:api_token, organization: org, user: alice)
    get api_tokens_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include("data-table")
  end

  it "create token shows raw token" do
    expect {
      post api_tokens_path, params: { api_token: { name: "Test Token" } }
    }.to change(ApiToken, :count).by(1)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("token-reveal")
  end

  it "revoke token" do
    token = create(:api_token, organization: org, user: alice)
    expect(token).not_to be_revoked
    patch revoke_api_token_path(token)
    expect(response).to redirect_to(api_tokens_path)
    token.reload
    expect(token).to be_revoked
  end

  it "requires authentication" do
    delete sign_out_path
    get api_tokens_path
    expect(response).to redirect_to(sign_in_path)
  end
end
