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
      get "/l/hampton/liveorder/q3/cart-roadmap"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("LiveOrder Cart Roadmap")
    end

    it "serves each ancestor of that path" do
      [
        "/l/hampton/liveorder/q3",
        "/l/hampton/liveorder",
        "/l/hampton",
        "/l"
      ].each do |path|
        get path
        expect(response).to have_http_status(:ok), "expected #{path} to be a real page"
      end
    end

    it "404s a path that names nothing" do
      get "/l/hampton/liveorder/nope"
      expect(response).to have_http_status(:not_found)

      get "/l/nobody"
      expect(response).to have_http_status(:not_found)
    end

    it "does not treat a dotted slug tail as a format" do
      versioned = create(:plan, :published, created_by_user: author, title: "Pricing v1.2")
      place(versioned, folder)

      get "/l/hampton/liveorder/#{versioned.slug}"

      expect(response).to have_http_status(:ok)
      expect(versioned.slug).to eq("pricing-v1-2")
    end
  end

  describe "the owner's own library" do
    let!(:folder) { create(:folder, name: "Team EBT", created_by_user: author) }

    before { sign_in_as(author) }

    it "renders the editable workspace at the browsable path" do
      get "/l/hampton/team-ebt"

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

      get "/l/hampton/liveorder/cart-roadmap"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/l/hampton/live-order-platform/cart-roadmap")
    end

    it "301s a whole renamed subtree with one alias" do
      folder = create(:folder, name: "LiveOrder", created_by_user: author)
      nested = create(:folder, name: "Q3", parent: folder, created_by_user: author)
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
      place(plan, nested)

      expect { folder.update!(name: "Orders") }
        .to change(CoPlan::UrlAlias, :count).by(1)

      get "/l/hampton/liveorder/q3/cart-roadmap"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/l/hampton/orders/q3/cart-roadmap")
    end

    it "301s to the new path after a published plan is retitled" do
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")

      plan.update!(title: "Basket Roadmap")

      get "/l/hampton/cart-roadmap"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/l/hampton/basket-roadmap")
    end

    it "301s after a library handle is renamed" do
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
      author.library.update!(handle: "hampton-lc")

      get "/l/hampton/cart-roadmap"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/l/hampton-lc/cart-roadmap")
      expect(plan.reload.url_path).to eq("hampton-lc/cart-roadmap")
    end
  end

  describe "legacy URLs" do
    before { sign_in_as(viewer) }

    it "301s an id-based library link to the browsable path" do
      get "/libraries/#{author.library.id}"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/l/hampton")
    end

    it "301s an id-based folder link to the browsable path" do
      folder = create(:folder, name: "Team EBT", created_by_user: author)

      get "/libraries/#{author.library.id}?folder=#{folder.id}"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/l/hampton/team-ebt")
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

      get "/l/hampton/secret-roadmap"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Secret Roadmap")

      get "/l/hampton"
      expect(response.body).not_to include("Secret Roadmap")
    end
  end
end
