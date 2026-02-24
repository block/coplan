require "rails_helper"

RSpec.describe "Api::V1::Plans", type: :request do
  let(:org) { create(:organization) }
  let(:other_org) { create(:organization, allowed_email_domains: ["other.com"]) }
  let(:alice) { create(:user, :admin, organization: org) }
  let(:carol) { create(:user, :admin, organization: other_org, email: "carol@other.com") }
  let(:alice_token) { create(:api_token, organization: org, user: alice, raw_token: "test-token-alice") }
  let(:carol_token) { create(:api_token, organization: other_org, user: carol, raw_token: "test-token-carol") }
  let(:revoked_token) { create(:api_token, :revoked, organization: org, user: alice, raw_token: "test-token-revoked") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:plan) { create(:plan, :considering, organization: org, created_by_user: alice, title: "Acme Roadmap") }

  before do
    alice_token # ensure token exists
  end

  it "index returns plans" do
    plan # trigger creation
    get api_v1_plans_path, headers: headers
    expect(response).to have_http_status(:success)
    plans = JSON.parse(response.body)
    expect(plans.any? { |p| p["title"] == "Acme Roadmap" }).to be true
  end

  it "index excludes other org plans" do
    plan # trigger creation
    carol_token # ensure token exists
    get api_v1_plans_path, headers: { "Authorization" => "Bearer test-token-carol" }
    expect(response).to have_http_status(:success)
    plans = JSON.parse(response.body)
    expect(plans.any? { |p| p["title"] == "Acme Roadmap" }).to be false
  end

  it "index requires auth" do
    get api_v1_plans_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "index with revoked token" do
    revoked_token # ensure token exists
    get api_v1_plans_path, headers: { "Authorization" => "Bearer test-token-revoked" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "show returns plan" do
    get api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:success)
    body = JSON.parse(response.body)
    expect(body["title"]).to eq("Acme Roadmap")
    expect(body["current_content"]).to be_present
  end

  it "show returns 404 for other org plan" do
    carol_token # ensure token exists
    get api_v1_plan_path(plan), headers: { "Authorization" => "Bearer test-token-carol" }
    expect(response).to have_http_status(:not_found)
  end

  it "create creates new plan" do
    expect {
      post api_v1_plans_path, params: { title: "API Plan", content: "# API Plan\n\nCreated via API." }, headers: headers, as: :json
    }.to change(Plan, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["title"]).to eq("API Plan")
    expect(body["current_revision"]).to eq(1)
  end

  it "create without title fails" do
    post api_v1_plans_path, params: { content: "no title" }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "versions returns version list" do
    get versions_api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:success)
    versions = JSON.parse(response.body)
    expect(versions.any? { |v| v["revision"] == 1 }).to be true
  end

  it "comments returns thread list" do
    get comments_api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:success)
    threads = JSON.parse(response.body)
    expect(threads).to be_a(Array)
  end
end
