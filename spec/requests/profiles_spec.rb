require "rails_helper"

# A person's page and their library are one page: /<handle>. This file is
# about the old /people/:id address still landing you there, and about
# author links across the app pointing at it. What the page *shows* is
# covered where it's rendered — see spec/requests/libraries_spec.rb.
RSpec.describe "Profiles", type: :request do
  let(:viewer) { create(:coplan_user, name: "Vera Viewer") }
  let!(:author) { create(:coplan_user, name: "Ada Author", username: "ada.a", title: "Engineer", team: "Payments") }

  describe "GET /people/:id" do
    before { sign_in_as(viewer) }

    # A username can hold characters a handle can't — "ada.a" becomes the
    # handle "ada-a" — so this is a translation, not a prefix trim.
    it "301s a username link onto the person's library" do
      get legacy_person_path("ada.a")

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(browse_library_path(handle: "ada-a"))
    end

    it "301s an id link onto the person's library" do
      get legacy_person_path(author.id)

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(browse_library_path(handle: "ada-a"))
    end

    it "404s for an unknown person" do
      get legacy_person_path("nobody-here")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "author links" do
    before { sign_in_as(viewer) }

    it "links the plan header author name to their library" do
      plan = create(:plan, :considering, created_by_user: author, title: "Linked Plan")

      get plan_page_path(plan)
      expect(response.body).to include(%(href="/ada-a"))
    end
  end
end
