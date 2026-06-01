require "rails_helper"

RSpec.describe "Search (COPLAN-21)", type: :request do
  # InnoDB FULLTEXT writes are invisible to MATCH … AGAINST inside the same
  # transaction (the FTS index keeps its own visibility tracking). Run these
  # request specs without transactional fixtures and TRUNCATE between examples
  # so the FULLTEXT index actually picks up our seed rows.
  self.use_transactional_tests = false

  after do
    ActiveRecord::Base.connection.execute("SET FOREIGN_KEY_CHECKS = 0")
    %w[coplan_plan_tags coplan_tags coplan_plan_versions coplan_plans
       coplan_search_queries coplan_users].each do |t|
      ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{t}")
    end
    ActiveRecord::Base.connection.execute("SET FOREIGN_KEY_CHECKS = 1")
  end

  let!(:alice) { create(:coplan_user, name: "Alice Searcher") }
  let!(:bob)   { create(:coplan_user, name: "Bob Other") }

  let!(:alice_published) do
    create(:plan, :considering, created_by_user: alice, title: "Quarterly Sitewide Roadmap")
  end

  let!(:bob_published) do
    create(:plan, :considering, created_by_user: bob, title: "Search Infrastructure RFC")
  end

  let!(:alice_brainstorm) do
    create(:plan, :brainstorm, created_by_user: alice, title: "Personal Brainstorm Memo")
  end

  describe "GET /search" do
    context "signed-in" do
      before { sign_in_as(alice) }

      it "returns a full-page result list when no frame param is given" do
        get search_path, params: { q: "roadmap" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Quarterly Sitewide Roadmap")
        expect(response.body).to include("<turbo-frame id=\"search-results\">")
      end

      it "returns only the results partial when frame=results" do
        get search_path, params: { q: "roadmap", frame: "results" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("<turbo-frame id=\"search-results\">")
        expect(response.body).not_to include("<html") # layout suppressed
        expect(response.body).to include("Quarterly Sitewide Roadmap")
      end

      it "logs the query to recent searches" do
        expect {
          get search_path, params: { q: "roadmap" }
        }.to change { CoPlan::SearchQuery.where(user: alice).count }.by(1)
      end

      it "includes the signed-in user's own brainstorm plans in results" do
        get search_path, params: { q: "brainstorm" }
        expect(response.body).to include("Personal Brainstorm Memo")
      end

      it "renders 'no results' messaging when nothing matches" do
        get search_path, params: { q: "noplanmatcheszzz" }
        expect(response.body).to include("No plans match")
      end

      it "renders 'Type to search' when query is blank" do
        get search_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Type to search")
      end
    end

    context "signed-out" do
      it "allows anonymous access" do
        get search_path, params: { q: "roadmap" }
        expect(response).to have_http_status(:ok)
      end

      it "returns only published plans (brainstorm hidden)" do
        get search_path, params: { q: "brainstorm" }
        expect(response.body).not_to include("Personal Brainstorm Memo")
      end

      it "does not persist a SearchQuery row" do
        expect {
          get search_path, params: { q: "roadmap" }
        }.not_to change { CoPlan::SearchQuery.count }
      end
    end
  end

  describe "header search bar in the layout" do
    it "is visible to signed-out users" do
      get root_path
      expect(response.body).to include('class="site-nav__search"')
      expect(response.body).to include('popovertarget="search-modal"')
    end

    it "renders the search modal in the layout once" do
      get root_path
      expect(response.body.scan('id="search-modal"').size).to eq(1)
    end
  end
end
