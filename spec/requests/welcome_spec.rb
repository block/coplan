require "rails_helper"

RSpec.describe "Welcome", type: :request do
  let(:alice) { create(:coplan_user) }
  let(:bob) { create(:coplan_user) }

  describe "GET /" do
    context "signed-in user with no plans" do
      before { sign_in_as(bob) }

      it "renders the landing page" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Design docs, built for AI-assisted planning")
      end

      it "shows a 'Browse plans' CTA for signed-in users" do
        get root_path
        expect(response.body).to include("Browse plans")
      end
    end

    context "signed-in user with at least one plan" do
      before do
        sign_in_as(alice)
        create(:plan, :considering, created_by_user: alice)
      end

      it "redirects to the plans index" do
        get root_path
        expect(response).to redirect_to(plans_path)
      end

      it "renders the landing page when force=1 is passed (escape hatch)" do
        get root_path(force: 1)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Design docs, built for AI-assisted planning")
      end
    end
  end

  describe "GET /welcome" do
    context "signed-in user with plans" do
      before do
        sign_in_as(alice)
        create(:plan, :considering, created_by_user: alice)
      end

      it "redirects to the plans index just like /" do
        get welcome_path
        expect(response).to redirect_to(plans_path)
      end
    end

    context "signed-in user without plans" do
      before { sign_in_as(bob) }

      it "renders the landing page" do
        get welcome_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Design docs, built for AI-assisted planning")
      end
    end
  end

  describe "landing_page_partial configuration override" do
    around do |ex|
      original = CoPlan.configuration.landing_page_partial
      CoPlan.configuration.landing_page_partial = "coplan/welcome/test_landing_override"
      ex.run
      CoPlan.configuration.landing_page_partial = original
    end

    before do
      sign_in_as(bob)
      # Create a temporary partial under engine view paths so we can verify the
      # configured partial is what gets rendered. Cleaned up in `after`.
      view_path = CoPlan::Engine.root.join("app/views/coplan/welcome/_test_landing_override.html.erb")
      File.write(view_path, "<div class=\"custom-host-landing\">Square-flavored landing</div>\n")
      @tmp_view = view_path
    end

    after { File.delete(@tmp_view) if @tmp_view&.exist? }

    it "renders the host-configured partial instead of the default" do
      get welcome_path
      expect(response.body).to include("Square-flavored landing")
      expect(response.body).not_to include("Design docs, built for AI-assisted planning")
    end
  end

  describe "landing_agents_partial configuration override" do
    # The agents section is the one piece of the landing page we expect hosts
    # to most often swap out (generic /agent-instructions vs deployment-
    # specific install commands like `sq agents skills add coplan`). Verify
    # the swap happens *and* that the rest of the landing page is untouched.

    before { sign_in_as(bob) }

    context "with the default partial" do
      it "renders the generic agents section pointing at /agent-instructions" do
        get welcome_path
        expect(response.body).to include("Built for any AI agent")
        expect(response.body).to include("/agent-instructions")
      end
    end

    context "with a host-configured override" do
      around do |ex|
        original = CoPlan.configuration.landing_agents_partial
        CoPlan.configuration.landing_agents_partial = "coplan/welcome/test_agents_override"
        ex.run
        CoPlan.configuration.landing_agents_partial = original
      end

      before do
        view_path = CoPlan::Engine.root.join("app/views/coplan/welcome/_test_agents_override.html.erb")
        File.write(view_path, "<section class=\"host-agents\">sq agents skills add coplan</section>\n")
        @tmp_view = view_path
      end

      after { File.delete(@tmp_view) if @tmp_view&.exist? }

      it "swaps the agents section while keeping the rest of the landing page" do
        get welcome_path

        # The host's agents copy is rendered…
        expect(response.body).to include("sq agents skills add coplan")
        # …the default agents copy is gone…
        expect(response.body).not_to include("Built for any AI agent")
        # …but the hero and how-it-works steps are still the engine defaults.
        expect(response.body).to include("Design docs, built for AI-assisted planning")
        expect(response.body).to include("How it works")
      end
    end
  end
end
