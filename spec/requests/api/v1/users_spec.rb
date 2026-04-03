require "rails_helper"

RSpec.describe "Api::V1::Users", type: :request do
  let(:user) { create(:coplan_user) }
  let(:api_token) { create(:api_token, user: user, raw_token: "test-token-users") }
  let(:headers) { { "Authorization" => "Bearer test-token-users" } }

  before { api_token }

  describe "GET /api/v1/users/search" do
    it "requires authentication" do
      get search_api_v1_users_path, params: { q: "alice" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns empty array for blank query" do
      get search_api_v1_users_path, params: { q: "" }, headers: headers
      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body)).to eq([])
    end

    it "returns empty array for missing query" do
      get search_api_v1_users_path, headers: headers
      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body)).to eq([])
    end

    context "fallback LIKE search" do
      let!(:alice) { create(:coplan_user, name: "Alice Smith", email: "alice@example.com", title: "Engineer", team: "Platform") }
      let!(:bob) { create(:coplan_user, name: "Bob Jones", email: "bob@example.com") }

      it "searches by name" do
        get search_api_v1_users_path, params: { q: "Alice" }, headers: headers
        results = JSON.parse(response.body)
        expect(results.length).to eq(1)
        expect(results.first["name"]).to eq("Alice Smith")
        expect(results.first["title"]).to eq("Engineer")
        expect(results.first["team"]).to eq("Platform")
      end

      it "searches by email" do
        get search_api_v1_users_path, params: { q: "bob@" }, headers: headers
        results = JSON.parse(response.body)
        expect(results.length).to eq(1)
        expect(results.first["name"]).to eq("Bob Jones")
      end

      it "returns user JSON with expected fields" do
        get search_api_v1_users_path, params: { q: "Alice" }, headers: headers
        result = JSON.parse(response.body).first
        expect(result.keys).to match_array(%w[id name email avatar_url title team])
      end
    end

    context "with user_search hook configured" do
      let(:hook_results) { [{ id: "ext-1", name: "Hooked User", email: "hooked@example.com", secret: "should-not-leak" }] }

      before do
        CoPlan.configuration.user_search = ->(query) { hook_results }
      end

      after do
        CoPlan.configuration.user_search = nil
      end

      it "delegates to the hook and filters fields" do
        get search_api_v1_users_path, params: { q: "hooked" }, headers: headers
        results = JSON.parse(response.body)
        expect(results.length).to eq(1)
        expect(results.first["name"]).to eq("Hooked User")
        expect(results.first.keys).to match_array(%w[id name email avatar_url title team])
        expect(results.first).not_to have_key("secret")
      end
    end
  end
end
