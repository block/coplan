require "rails_helper"

RSpec.describe "Api::V1::Leases", type: :request do
  let(:org) { create(:organization) }
  let(:alice) { create(:user, :admin, organization: org) }
  let(:bob) { create(:user, organization: org) }
  let(:alice_token) { create(:api_token, organization: org, user: alice, raw_token: "test-token-alice") }
  let(:bob_token) { create(:api_token, organization: org, user: bob, raw_token: "test-token-bob") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:plan) { create(:plan, :considering, organization: org, created_by_user: alice) }

  before do
    alice_token # ensure token exists
  end

  it "acquire lease" do
    post api_v1_plan_lease_path(plan),
      params: { lease_token: "my-token" },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["lease_token"]).to eq("my-token")
    expect(body["expires_at"]).to be_present
  end

  it "acquire lease generates token if not provided" do
    post api_v1_plan_lease_path(plan), headers: headers, as: :json
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["lease_token"]).to be_present
  end

  it "acquire lease conflicts when held by another" do
    post api_v1_plan_lease_path(plan),
      params: { lease_token: "first-token" },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:created)

    bob_token # ensure bob's token exists
    bob_headers = { "Authorization" => "Bearer test-token-bob" }
    post api_v1_plan_lease_path(plan),
      params: { lease_token: "second-token" },
      headers: bob_headers,
      as: :json
    expect(response).to have_http_status(:conflict)
  end

  it "renew lease" do
    post api_v1_plan_lease_path(plan),
      params: { lease_token: "my-token" },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:created)

    patch api_v1_plan_lease_path(plan),
      params: { lease_token: "my-token" },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:success)
  end

  it "renew lease with wrong token" do
    post api_v1_plan_lease_path(plan),
      params: { lease_token: "my-token" },
      headers: headers,
      as: :json

    patch api_v1_plan_lease_path(plan),
      params: { lease_token: "wrong-token" },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:conflict)
  end

  it "release lease" do
    post api_v1_plan_lease_path(plan),
      params: { lease_token: "my-token" },
      headers: headers,
      as: :json

    delete api_v1_plan_lease_path(plan),
      params: { lease_token: "my-token" },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:no_content)
    expect(EditLease.find_by(plan_id: plan.id)).to be_nil
  end
end
