require "rails_helper"

RSpec.describe "Libraries", type: :request do
  let(:alice) { create(:coplan_user, username: "alice") }

  before { sign_in_as(alice) }

  describe "GET /_/libraries" do
    # A library exists from the moment its owner does — it's a person's page
    # now, so a colleague who has never signed in is still browsable.
    it "lists the libraries you can browse" do
      create(:coplan_user, username: "bob")

      get browse_root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(href="/alice"), %(href="/bob"))
    end

    # The eager row above is the invariant; `User#library` is the belt to its
    # braces, for anything that removed a row out from under it.
    it "includes your own library even when the row has gone missing" do
      alice.library.destroy!

      get browse_root_path

      expect(response.body).to include(%(href="/alice"))
    end

    # The count has to say what clicking the row will show. A plan at a
    # library root has no placement row by design, so counting placements
    # alone called a library of nothing but loose work "empty".
    it "counts the plans sitting loose at a library root" do
      bob = create(:coplan_user, username: "bob")
      create(:plan, :published, created_by_user: bob, title: "Loose plan")

      get browse_root_path

      expect(response.body).to include("1 plan")
    end

    it "counts filed and loose plans together" do
      bob = create(:coplan_user, username: "bob")
      folder = create(:folder, name: "Projects", created_by_user: bob)
      filed = create(:plan, :published, created_by_user: bob, title: "Filed plan")
      create(:plan_placement, plan: filed, folder: folder)
      create(:plan, :published, created_by_user: bob, title: "Loose plan")

      get browse_root_path

      expect(response.body).to include("2 plans")
    end
  end

  describe "GET /library" do
    it "redirects to the current user's browsable library root" do
      get my_library_path
      expect(response).to redirect_to(browse_library_path(handle: "alice"))
    end
  end

  # The id-based form is legacy: it 301s to the canonical browsable path so
  # old links converge on the readable URL rather than living alongside it.
  describe "GET /libraries/:id" do
    it "301s a library link to its browsable path" do
      get library_path(alice.library)

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(browse_library_path(handle: "alice"))
    end

    it "301s a folder link to its browsable path" do
      folder = create(:folder, name: "Team EBT", created_by_user: alice)

      get library_path(alice.library, folder: folder.id)

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(browse_path(handle: "alice", slug_path: "team-ebt"))
    end

    it "returns to the library root when the requested folder is gone" do
      bob = create(:coplan_user, username: "bob")

      get library_path(bob.library, folder: "missing")

      expect(response).to redirect_to(browse_library_path(handle: "bob"))
      expect(flash[:alert]).to eq("That folder no longer exists.")
    end
  end

  describe "browsing another user's library" do
    let(:bob) { create(:coplan_user, username: "bob") }
    let!(:projects) { create(:folder, name: "Projects", created_by_user: bob) }
    let!(:launches) { create(:folder, name: "Launches", parent: projects, created_by_user: bob) }
    let!(:filed) { create(:plan, :published, title: "Filed launch", created_by_user: bob) }
    let!(:loose) { create(:plan, :published, title: "Loose plan", created_by_user: bob) }
    let!(:private_plan) { create(:plan, :draft, title: "Private draft", created_by_user: bob) }

    before do
      create(:plan_placement, plan: filed, folder: launches)
      create(:plan_placement, plan: private_plan, folder: launches)
    end

    it "walks one folder level at a time" do
      # The library root also carries a "since you last looked" strip, which
      # would surface Bob's work wherever it's filed — so mark it read first
      # and let this example be about the level listing alone. The strip has
      # its own example below.
      [ filed, loose ].each { |plan| CoPlan::PlanViewer.track(plan: plan, user: alice) }

      get "/bob"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Projects", "Loose plan")
      expect(response.body).not_to include("Filed launch", "Private draft")

      get "/bob/projects"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Projects", "Launches")
      expect(response.body).not_to include("Filed launch", "Loose plan")

      get "/bob/projects/launches"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Projects", "Launches", "Filed launch")
      expect(response.body).not_to include("Loose plan", "Private draft")
    end

    # The same interface you get on your own library: filters, folder counts,
    # and this. In someone else's library it answers "what's new in here",
    # which is the question you came to their library with.
    it "shows what's changed since you last looked" do
      get "/bob"

      expect(response.body).to include("Since you last looked", "new to you")
    end

    # Read-only, not read-a-different-page: the sidebar and its counts are
    # the same ones the owner sees, bounded by what you're allowed to see.
    it "offers the same filters, and no controls you can't use" do
      get "/bob"

      expect(response.body).to include("Filters &amp; folders", "Read only")
      expect(response.body).to include(%(href="/bob?filter=archived"))
      expect(response.body).not_to include("New folder")
      expect(response.body).not_to include("Show my private plans")
    end

    # Folder navigation is a path, so clicking one inside someone's library
    # stays inside it. Getting this wrong sent you back to your own workspace.
    it "keeps folder links inside the library being browsed" do
      get "/bob"

      expect(response.body).to include(%(href="/bob/projects"))
      expect(response.body).not_to include("/_/plans?folder=")
    end
  end

  # A person's page and their library are one page, so the identity that
  # used to live on /people/:id is the header of this one.
  describe "the person at the top of their library" do
    let!(:author) do
      create(:coplan_user, name: "Ada Author", username: "ada", title: "Engineer", team: "Payments")
    end

    it "names the person, their role, and their handle" do
      get "/ada"

      expect(response.body).to include("Ada Author", "Engineer", "Payments", "/ada")
    end

    describe "directory adapter" do
      after { CoPlan.configuration.directory_profile = nil }

      it "overrides local fields and adds a directory link" do
        CoPlan.configuration.directory_profile = ->(_user) {
          { title: "Staff Engineer", profile_url: "https://people.example.com/ada" }
        }

        get "/ada"

        expect(response.body).to include("Staff Engineer")
        expect(response.body).not_to include(">Engineer<")
        expect(response.body).to include("https://people.example.com/ada")
      end

      it "falls back to the local profile when the hook raises" do
        reported = []
        allow(CoPlan.configuration).to receive(:error_reporter).and_return(->(e, _ctx) { reported << e })
        CoPlan.configuration.directory_profile = ->(_user) { raise "directory down" }

        get "/ada"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Ada Author", "Engineer")
        expect(reported.size).to eq(1)
      end
    end

    # Drafts are unlisted, not locked. Your own library shows yours — it's
    # your workspace — and nobody else's library shows them to you.
    it "lists a draft to its author and to no one else" do
      create(:plan, :draft, created_by_user: author, title: "Secret Draft")

      sign_in_as(author)
      get "/ada"
      expect(response.body).to include("Secret Draft")

      sign_in_as(alice)
      get "/ada"
      expect(response.body).not_to include("Secret Draft")
    end

    it "hides an archived plan until someone asks for the archive" do
      create(:plan, :published, created_by_user: author, title: "Old Work", archived_at: 1.day.ago)

      get "/ada"
      expect(response.body).not_to include("Old Work")

      get "/ada?filter=archived"
      expect(response.body).to include("Old Work")
    end
  end
end
