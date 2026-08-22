require "rails_helper"

RSpec.describe "Browsable library URLs", type: :request do
  let(:author) { create(:coplan_user, username: "hampton") }
  let(:viewer) { create(:coplan_user, username: "viewer") }

  def place(plan, folder, actor: author)
    CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: actor)
    plan.reload
  end

  describe "every prefix is a real page" do
    let!(:folder) { create(:folder, name: "LiveOrder", created_by_user: author) }
    let!(:nested) { create(:folder, name: "Q3", parent: folder, created_by_user: author) }
    let!(:plan) do
      create(:plan, :published, created_by_user: author, title: "LiveOrder Cart Roadmap")
        .tap { |p| place(p, nested) }
    end

    before { sign_in_as(viewer) }

    it "serves the plan at its canonical path" do
      get "/hampton/liveorder/q3/cart-roadmap"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("LiveOrder Cart Roadmap")
    end

    it "serves each ancestor of that path" do
      [
        "/hampton/liveorder/q3",
        "/hampton/liveorder",
        "/hampton",
        "/_/libraries"
      ].each do |path|
        get path
        expect(response).to have_http_status(:ok), "expected #{path} to be a real page"
      end
    end

    it "404s a path that names nothing" do
      get "/hampton/liveorder/nope"
      expect(response).to have_http_status(:not_found)

      get "/nobody"
      expect(response).to have_http_status(:not_found)
    end

    it "does not treat a dotted slug tail as a format" do
      versioned = create(:plan, :published, created_by_user: author, title: "Pricing v1.2")
      place(versioned, folder)

      get "/hampton/liveorder/#{versioned.slug}"

      expect(response).to have_http_status(:ok)
      expect(versioned.slug).to eq("pricing-v1-2")
    end
  end

  describe "the owner's own library" do
    let!(:folder) { create(:folder, name: "Team EBT", created_by_user: author) }

    before { sign_in_as(author) }

    it "renders the editable workspace at the browsable path" do
      get "/hampton/team-ebt"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Team EBT")
    end
  end

  describe "stale paths" do
    before { sign_in_as(viewer) }

    it "301s to the new path after a folder is renamed" do
      folder = create(:folder, name: "LiveOrder", created_by_user: author)
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
      place(plan, folder)

      folder.update!(name: "Live Order Platform")

      get "/hampton/liveorder/cart-roadmap"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/hampton/live-order-platform/cart-roadmap")
    end

    it "301s a whole renamed subtree with one alias" do
      folder = create(:folder, name: "LiveOrder", created_by_user: author)
      nested = create(:folder, name: "Q3", parent: folder, created_by_user: author)
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
      place(plan, nested)

      expect { folder.update!(name: "Orders") }
        .to change(CoPlan::UrlAlias, :count).by(1)

      get "/hampton/liveorder/q3/cart-roadmap"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/hampton/orders/q3/cart-roadmap")
    end

    it "301s to the new path after a published plan is retitled" do
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")

      plan.update!(title: "Basket Roadmap")

      get "/hampton/cart-roadmap"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/hampton/basket-roadmap")
    end

    it "301s after a library handle is renamed" do
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
      author.library.update!(handle: "hampton-lc")

      get "/hampton/cart-roadmap"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/hampton-lc/cart-roadmap")
      expect(plan.reload.url_path).to eq("hampton-lc/cart-roadmap")
    end

    # The renamed thing's own address, not just the ones beneath it. A
    # prefix alias has to match the whole path as well as its ancestors, or
    # a rename fixes every link into a folder except the link to the folder.
    it "301s the renamed folder's own path" do
      folder = create(:folder, name: "LiveOrder", created_by_user: author)

      folder.update!(name: "Orders")

      get "/hampton/liveorder"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/hampton/orders")
    end

    it "301s the renamed library's own root" do
      author.library.update!(handle: "hampton-lc")

      get "/hampton"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/hampton-lc")
    end
  end

  describe "legacy URLs" do
    before { sign_in_as(viewer) }

    it "301s an id-based library link to the browsable path" do
      get "/libraries/#{author.library.id}"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/hampton")
    end

    it "301s an id-based folder link to the browsable path" do
      folder = create(:folder, name: "Team EBT", created_by_user: author)

      get "/libraries/#{author.library.id}?folder=#{folder.id}"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/hampton/team-ebt")
    end

    # /plans/<uuid> is the old name for the page, not a redirect-of-the-day:
    # 301 so the address bar — and everything copied out of it — converges
    # on the readable form.
    describe "/plans/<uuid>" do
      let!(:plan) { create(:plan, :published, created_by_user: author, title: "Cart Roadmap") }

      it "301s onto the document's readable address" do
        get "/plans/#{plan.id}"

        expect(response).to have_http_status(:moved_permanently)
        expect(response.headers["Location"]).to end_with("/hampton/cart-roadmap")
      end

      it "carries the query string over" do
        get "/plans/#{plan.id}?thread=abc123"

        expect(response.headers["Location"]).to end_with("/hampton/cart-roadmap?thread=abc123")
      end

      it "still names the readable URL as canonical when it does render" do
        get "/hampton/cart-roadmap"

        expect(response.body).to include(
          %(<link rel="canonical" href="http://www.example.com/hampton/cart-roadmap">)
        )
      end

      # A Turbo Frame fetch and a non-HTML caller asked for this exact URL
      # and want a response, not a hop.
      it "does not bounce a Turbo Frame fetch" do
        get "/plans/#{plan.id}", headers: { "Turbo-Frame" => "plan-content" }

        expect(response).to have_http_status(:ok)
      end

      # Nothing to converge on yet: both forms have to work while slugs
      # backfill, so an unslugged plan renders at its id.
      it "renders in place for a plan with no slug yet" do
        plan.update_columns(slug: nil)

        get "/plans/#{plan.id}"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Cart Roadmap")
      end
    end
  end

  describe "drafts" do
    before { sign_in_as(viewer) }

    # Drafts are unlisted, not locked (PlanPolicy#show?), so a readable URL
    # doesn't change who can reach one — access was never URL secrecy. What
    # a draft withholds is discovery, and that stays with Plan.visible_to.
    it "is readable by direct path but stays out of the library listing" do
      plan = create(:plan, :draft, created_by_user: author, title: "Secret Roadmap")
      expect(plan.reload.slug).to eq("secret-roadmap")

      get "/hampton/secret-roadmap"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Secret Roadmap")

      get "/hampton"
      expect(response.body).not_to include("Secret Roadmap")
    end
  end
end
