require "rails_helper"

RSpec.describe "Libraries", type: :request do
  let(:alice) { create(:coplan_user, username: "alice") }

  before { sign_in_as(alice) }

  describe "GET /l" do
    it "lists the libraries you can browse" do
      bob = create(:coplan_user, username: "bob")
      bob.library # materialize

      get browse_root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/l/alice", "/l/bob")
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
    it "walks one folder level at a time" do
      bob = create(:coplan_user, username: "bob")
      projects = create(:folder, name: "Projects", created_by_user: bob)
      launches = create(:folder, name: "Launches", parent: projects, created_by_user: bob)
      filed = create(:plan, :published, title: "Filed launch", created_by_user: bob)
      create(:plan, :published, title: "Loose plan", created_by_user: bob)
      private_plan = create(:plan, :draft, title: "Private draft", created_by_user: bob)
      create(:plan_placement, plan: filed, folder: launches)
      create(:plan_placement, plan: private_plan, folder: launches)

      get "/l/bob"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Projects", "Loose plan")
      expect(response.body).not_to include("Filed launch", "Private draft")

      get "/l/bob/projects"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Projects", "Launches")
      expect(response.body).not_to include("Filed launch", "Loose plan")

      get "/l/bob/projects/launches"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Projects", "Launches", "Filed launch")
      expect(response.body).not_to include("Loose plan", "Private draft")
    end
  end
end
