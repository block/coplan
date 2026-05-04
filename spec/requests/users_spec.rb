require "rails_helper"

RSpec.describe "Users", type: :request do
  describe "GET /users/search" do
    let!(:viewer) { create(:coplan_user) }
    let!(:alice) { create(:coplan_user, name: "Alice Smith", email: "alice@example.com", title: "Engineer", team: "Platform") }
    let!(:bob) { create(:coplan_user, name: "Bob Jones", email: "bob@example.com") }

    it "redirects unauthenticated browser requests to sign-in" do
      get search_users_path, params: { q: "alice" }
      expect(response).to have_http_status(:redirect).or have_http_status(:unauthorized)
    end

    context "when signed in" do
      before { sign_in_as(viewer) }

      it "returns empty array for blank query" do
        get search_users_path, params: { q: "" }
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)).to eq([])
      end

      it "searches by name" do
        get search_users_path, params: { q: "Alice" }
        results = JSON.parse(response.body)
        expect(results.map { |r| r["name"] }).to include("Alice Smith")
      end

      it "searches by email" do
        get search_users_path, params: { q: "bob@" }
        results = JSON.parse(response.body)
        expect(results.map { |r| r["name"] }).to include("Bob Jones")
      end

      it "returns the expected JSON shape" do
        get search_users_path, params: { q: "Alice" }
        result = JSON.parse(response.body).find { |r| r["name"] == "Alice Smith" }
        expect(result.keys).to match_array(%w[id name email username avatar_url title team])
      end

      context "with user_search hook configured" do
        let!(:local_user) { create(:coplan_user, name: "Local Person", username: "localp") }

        before do
          # Hook returns one local user (resolvable) and one external-only user.
          CoPlan.configuration.user_search = ->(_query) {
            [
              { id: "ext-1", name: "External Only", email: "ext@example.com", username: "external_only" },
              { id: local_user.id, name: "Local Person", email: "local@example.com", username: "localp" }
            ]
          }
        end

        after { CoPlan.configuration.user_search = nil }

        it "filters out hook results whose username doesn't exist locally" do
          get search_users_path, params: { q: "anything" }
          results = JSON.parse(response.body)
          expect(results.map { |r| r["username"] }).to eq(["localp"])
        end
      end
    end
  end
end
