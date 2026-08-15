require "rails_helper"

RSpec.describe "Libraries", type: :request do
  let(:alice) { create(:coplan_user, username: "alice") }

  before { sign_in_as(alice) }

  describe "GET /library" do
    it "redirects to the current user's editable workspace" do
      get my_library_path
      expect(response).to redirect_to(plans_path)
    end
  end

  describe "GET /libraries/:id" do
    it "redirects the owner to the matching folder in their workspace" do
      folder = create(:folder, created_by_user: alice)

      get library_path(alice.library, folder: folder.id)

      expect(response).to redirect_to(plans_path(folder: folder.id))
    end

    it "browses another user's library one folder level at a time" do
      bob = create(:coplan_user, username: "bob")
      projects = create(:folder, name: "Projects", created_by_user: bob)
      launches = create(:folder, name: "Launches", parent: projects, created_by_user: bob)
      filed = create(:plan, :published, title: "Filed launch", created_by_user: bob)
      loose = create(:plan, :published, title: "Loose plan", created_by_user: bob)
      private_plan = create(:plan, :draft, title: "Private draft", created_by_user: bob)
      create(:plan_placement, plan: filed, folder: launches)
      create(:plan_placement, plan: private_plan, folder: launches)

      get library_path(bob.library)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Projects", "Loose plan")
      expect(response.body).not_to include("Filed launch", "Private draft")

      get library_path(bob.library, folder: projects.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Projects", "Launches")
      expect(response.body).not_to include("Filed launch", "Loose plan")

      get library_path(bob.library, folder: launches.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Projects", "Launches", "Filed launch")
      expect(response.body).not_to include("Loose plan", "Private draft")
    end

    it "returns to the library root when the requested folder is gone" do
      bob = create(:coplan_user)

      get library_path(bob.library, folder: "missing")

      expect(response).to redirect_to(library_path(bob.library))
      expect(flash[:alert]).to eq("That folder no longer exists.")
    end
  end
end
