require "rails_helper"

RSpec.describe "Api::V1::References", type: :request do
  let(:user) { create(:coplan_user) }
  let(:token) { create(:api_token, user: user, raw_token: "test-token-refs") }
  let(:headers) { { "Authorization" => "Bearer test-token-refs", "Content-Type" => "application/json" } }
  let(:plan) { create(:plan, :considering, created_by_user: user) }

  before { token }

  describe "GET /api/v1/plans/:plan_id/references" do
    it "lists references for a plan" do
      create(:reference, plan: plan, url: "https://github.com/org/repo", reference_type: "repository")
      create(:reference, plan: plan, url: "https://example.com", reference_type: "link")

      get api_v1_plan_references_path(plan), headers: headers
      expect(response).to have_http_status(:ok)

      data = JSON.parse(response.body)
      expect(data.length).to eq(2)
      expect(data.first).to include("url", "reference_type", "source")
    end

    it "filters by type" do
      create(:reference, plan: plan, url: "https://github.com/org/repo", reference_type: "repository")
      create(:reference, plan: plan, url: "https://example.com", reference_type: "link")

      get api_v1_plan_references_path(plan), params: { type: "repository" }, headers: headers
      data = JSON.parse(response.body)
      expect(data.length).to eq(1)
      expect(data.first["reference_type"]).to eq("repository")
    end
  end

  describe "POST /api/v1/plans/:plan_id/references" do
    it "creates an explicit reference" do
      post api_v1_plan_references_path(plan),
        params: { url: "https://github.com/org/repo", title: "My Repo" }.to_json,
        headers: headers

      expect(response).to have_http_status(:created)
      data = JSON.parse(response.body)
      expect(data["url"]).to eq("https://github.com/org/repo")
      expect(data["reference_type"]).to eq("repository")
      expect(data["source"]).to eq("explicit")
      expect(data["title"]).to eq("My Repo")
    end

    it "auto-classifies URL type" do
      post api_v1_plan_references_path(plan),
        params: { url: "https://github.com/org/repo/pull/42" }.to_json,
        headers: headers

      data = JSON.parse(response.body)
      expect(data["reference_type"]).to eq("pull_request")
    end
  end

  describe "DELETE /api/v1/plans/:plan_id/references/:id" do
    it "deletes a reference" do
      ref = create(:reference, plan: plan, url: "https://example.com")

      delete api_v1_plan_reference_path(plan, ref), headers: headers
      expect(response).to have_http_status(:no_content)
      expect(plan.references.count).to eq(0)
    end

    it "returns not found for unknown reference" do
      delete api_v1_plan_reference_path(plan, "nonexistent-id"), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/references/search" do
    it "finds plans by reference URL" do
      create(:reference, plan: plan, url: "https://github.com/org/repo")

      get search_api_v1_references_path, params: { url: "https://github.com/org/repo" }, headers: headers
      expect(response).to have_http_status(:ok)

      data = JSON.parse(response.body)
      expect(data.length).to eq(1)
      expect(data.first["plan_id"]).to eq(plan.id)
      expect(data.first["plan_title"]).to eq(plan.title)
    end

    it "requires url parameter" do
      get search_api_v1_references_path, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "excludes brainstorm plans from other users" do
      other_user = create(:coplan_user)
      brainstorm_plan = create(:plan, :brainstorm, created_by_user: other_user)
      create(:reference, plan: brainstorm_plan, url: "https://github.com/org/repo")

      get search_api_v1_references_path, params: { url: "https://github.com/org/repo" }, headers: headers
      data = JSON.parse(response.body)
      expect(data.length).to eq(0)
    end
  end
end
