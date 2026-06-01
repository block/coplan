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
        # Full-page route uses its own frame id to avoid colliding with the
        # layout-rendered modal frame.
        expect(response.body).to match(/<turbo-frame id="search-page-results"/)
      end

      it "returns only the results partial when frame=results" do
        get search_path, params: { q: "roadmap", frame: "results" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to match(/<turbo-frame id="search-results"/)
        expect(response.body).not_to include("<html") # layout suppressed
        expect(response.body).to include("Quarterly Sitewide Roadmap")
      end

      it "logs explicit navigations to recent searches" do
        expect {
          get search_path, params: { q: "roadmap" }
        }.to change { CoPlan::SearchQuery.where(user: alice).count }.by(1)
      end

      it "does NOT log typeahead requests (frame=results) to recent searches" do
        # Otherwise typing 'roadmap' would log r, ro, roa, … and evict the
        # user's real recent searches.
        expect {
          get search_path, params: { q: "r",   frame: "results" }
          get search_path, params: { q: "ro",  frame: "results" }
          get search_path, params: { q: "roa", frame: "results" }
        }.not_to change { CoPlan::SearchQuery.where(user: alice).count }
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
      it "redirects anonymous visitors to sign-in instead of leaking plan data" do
        get search_path, params: { q: "roadmap" }
        expect(response).to redirect_to("/sign_in")
      end

      it "does not persist a SearchQuery row" do
        expect {
          get search_path, params: { q: "roadmap" }
        }.not_to change { CoPlan::SearchQuery.count }
      end
    end
  end

  describe "header search bar in the layout" do
    it "is hidden from signed-out users" do
      get root_path
      expect(response.body).not_to include('class="site-nav__search"')
      expect(response.body).not_to include('id="search-modal"')
    end

    it "is visible to signed-in users" do
      sign_in_as(alice)
      # `/` redirects signed-in users who already have plans (alice does);
      # follow through to land on the actual plans index, which uses the
      # same layout we want to verify.
      get root_path
      follow_redirect! if response.redirect?
      expect(response.body).to include('class="site-nav__search"')
      expect(response.body.scan('id="search-modal"').size).to eq(1)
    end
  end
end
