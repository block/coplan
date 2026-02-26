require "rails_helper"

RSpec.describe "Settings::Tokens", type: :request do
  let(:org) { create(:organization) }
  let(:alice) { create(:user, :admin, organization: org) }

  before { sign_in_as(alice) }

  it "index shows tokens" do
    create(:api_token, user: alice)
    get settings_tokens_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include("data-table")
  end

  it "create token shows raw token" do
    expect {
      post settings_tokens_path, params: { api_token: { name: "Test Token" } }
    }.to change(CoPlan::ApiToken, :count).by(1)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("token-reveal")
  end

  it "create token saves token_prefix" do
    post settings_tokens_path, params: { api_token: { name: "Prefix Test" } }
    token = CoPlan::ApiToken.last
    expect(token.token_prefix).to be_present
    expect(token.token_prefix.length).to eq(8)
  end

  it "revoke token" do
    token = create(:api_token, user: alice)
    expect(token).not_to be_revoked
    delete settings_token_path(token)
    expect(response).to redirect_to(settings_tokens_path)
    token.reload
    expect(token).to be_revoked
  end

  it "requires authentication" do
    delete sign_out_path
    get settings_tokens_path
    expect(response).to redirect_to(sign_in_path)
  end
end
