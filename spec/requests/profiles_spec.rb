require "rails_helper"

RSpec.describe "Profiles", type: :request do
  let(:viewer) { create(:coplan_user, name: "Vera Viewer") }
  let!(:author) { create(:coplan_user, name: "Ada Author", username: "ada.a", title: "Engineer", team: "Payments") }

  before { sign_in_as(viewer) }

  describe "GET /people/:id" do
    it "renders the profile by username, dots included" do
      get profile_path("ada.a")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ada Author")
      expect(response.body).to include("Engineer")
      expect(response.body).to include("Payments")
    end

    it "renders the profile by user id" do
      get profile_path(author.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ada Author")
    end

    it "404s for an unknown person" do
      get profile_path("nobody-here")
      expect(response).to have_http_status(:not_found)
    end

    it "lists published plans but never drafts or archived plans" do
      create(:plan, :considering, created_by_user: author, title: "Public Work")
      create(:plan, :draft, created_by_user: author, title: "Secret Draft")
      create(:plan, :considering, created_by_user: author, title: "Old Work", archived_at: 1.day.ago)

      get profile_path(author.id)
      expect(response.body).to include("Public Work")
      expect(response.body).not_to include("Secret Draft")
      expect(response.body).not_to include("Old Work")
    end

    it "hides your own drafts on your own profile too — a profile is a public shelf" do
      create(:plan, :draft, created_by_user: viewer, title: "My Own Draft")

      get profile_path(viewer.id)
      expect(response.body).not_to include("My Own Draft")
    end

    it "shows the library shelves with only publicly listed placements" do
      folder = create(:folder, name: "Favorites", created_by_user: author)
      shown = create(:plan, :considering, created_by_user: author, title: "Shelved Public")
      hidden = create(:plan, :draft, created_by_user: author, title: "Shelved Draft")
      CoPlan::Plans::Place.call(plan: shown, folder: folder, actor: author)
      CoPlan::Plans::Place.call(plan: hidden, folder: folder, actor: author)

      get profile_path(author.id)
      expect(response.body).to include("Favorites")
      expect(response.body).to include("Shelved Public")
      expect(response.body).not_to include("Shelved Draft")
    end

    describe "directory adapter" do
      after { CoPlan.configuration.directory_profile = nil }

      it "overrides local fields and adds a directory link" do
        CoPlan.configuration.directory_profile = ->(user) {
          { title: "Staff Engineer", profile_url: "https://people.example.com/ada" }
        }

        get profile_path(author.id)
        expect(response.body).to include("Staff Engineer")
        expect(response.body).not_to include(">Engineer<")
        expect(response.body).to include("https://people.example.com/ada")
        expect(response.body).to include("View in directory")
      end

      it "falls back to the local profile when the hook raises" do
        reported = []
        allow(CoPlan.configuration).to receive(:error_reporter).and_return(->(e, ctx) { reported << e })
        CoPlan.configuration.directory_profile = ->(user) { raise "directory down" }

        get profile_path(author.id)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Ada Author")
        expect(response.body).to include("Engineer")
        expect(reported.size).to eq(1)
      end
    end
  end

  describe "author links" do
    it "links the plan header author name to their profile" do
      plan = create(:plan, :considering, created_by_user: author, title: "Linked Plan")

      get plan_path(plan)
      expect(response.body).to include(profile_path("ada.a"))
    end
  end
end
