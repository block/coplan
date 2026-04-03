require "rails_helper"

RSpec.describe "Api::V1::Plans", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:carol) { create(:coplan_user, :admin) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:carol_token) { create(:api_token, user: carol, raw_token: "test-token-carol") }
  let(:revoked_token) { create(:api_token, :revoked, user: alice, raw_token: "test-token-revoked") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:plan) { create(:plan, :considering, created_by_user: alice, title: "Acme Roadmap") }

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

  it "index shows all non-brainstorm plans to any authenticated user" do
    plan # trigger creation
    carol_token # ensure token exists
    get api_v1_plans_path, headers: { "Authorization" => "Bearer test-token-carol" }
    expect(response).to have_http_status(:success)
    plans = JSON.parse(response.body)
    expect(plans.any? { |p| p["title"] == "Acme Roadmap" }).to be true
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

  it "show returns plan for any authenticated user" do
    carol_token # ensure token exists
    get api_v1_plan_path(plan), headers: { "Authorization" => "Bearer test-token-carol" }
    expect(response).to have_http_status(:success)
  end

  it "create creates new plan" do
    expect {
      post api_v1_plans_path, params: { title: "API Plan", content: "# API Plan\n\nCreated via API." }, headers: headers, as: :json
    }.to change(CoPlan::Plan, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["title"]).to eq("API Plan")
    expect(body["current_revision"]).to eq(1)
  end

  it "create with plan_type_id" do
    plan_type = create(:plan_type)
    post api_v1_plans_path, params: { title: "Typed Plan", content: "# Typed", plan_type_id: plan_type.id }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["plan_type_id"]).to eq(plan_type.id)
    expect(body["plan_type_name"]).to eq(plan_type.name)
  end

  it "create with invalid plan_type_id returns 422" do
    post api_v1_plans_path, params: { title: "Bad Type", plan_type_id: "nonexistent-id" }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    body = JSON.parse(response.body)
    expect(body["error"]).to include("plan_type_id")
  end

  it "create without title fails" do
    post api_v1_plans_path, params: { content: "no title" }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  describe "PATCH /api/v1/plans/:id" do
    it "updates plan title" do
      patch api_v1_plan_path(plan), params: { title: "New Title" }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["title"]).to eq("New Title")
      expect(plan.reload.title).to eq("New Title")
    end

    it "updates plan status" do
      patch api_v1_plan_path(plan), params: { status: "developing" }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("developing")
      expect(plan.reload.status).to eq("developing")
    end

    it "updates plan tags" do
      patch api_v1_plan_path(plan), params: { tags: ["infra", "api"] }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["tags"]).to match_array(["infra", "api"])
      expect(plan.reload.tag_names).to match_array(["infra", "api"])
    end

    it "updates multiple fields at once" do
      patch api_v1_plan_path(plan), params: { title: "Updated", status: "developing", tags: ["v2"] }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["title"]).to eq("Updated")
      expect(body["status"]).to eq("developing")
      expect(body["tags"]).to eq(["v2"])
    end

    it "leaves unchanged fields alone" do
      original_title = plan.title
      patch api_v1_plan_path(plan), params: { tags: ["new-tag"] }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      expect(plan.reload.title).to eq(original_title)
    end

    it "rejects invalid status" do
      patch api_v1_plan_path(plan), params: { status: "invalid" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 403 for non-author (carol)" do
      carol_token
      patch api_v1_plan_path(plan), params: { title: "Hacked" }, headers: { "Authorization" => "Bearer test-token-carol" }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 for non-author" do
      bob = create(:coplan_user)
      bob_token = create(:api_token, user: bob, raw_token: "test-token-bob")
      patch api_v1_plan_path(plan), params: { title: "Nope" }, headers: { "Authorization" => "Bearer test-token-bob" }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "requires auth" do
      patch api_v1_plan_path(plan), params: { title: "No Auth" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "versions returns version list" do
    get versions_api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:success)
    versions = JSON.parse(response.body)
    expect(versions.any? { |v| v["revision"] == 1 }).to be true
  end

  it "comments returns thread list with anchor_text" do
    thread = create(:comment_thread, :with_anchor, plan: plan,
      plan_version: plan.current_plan_version, created_by_user: alice, anchor_text: "original roadmap text")
    get comments_api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:success)
    threads = JSON.parse(response.body)
    expect(threads).to be_a(Array)
    matching = threads.find { |t| t["id"] == thread.id }
    expect(matching["anchor_text"]).to eq("original roadmap text")
  end
end
