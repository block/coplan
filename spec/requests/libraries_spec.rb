require "rails_helper"

# Libraries are a data concept, not a destination: these routes exist so
# old links keep working, and both redirect to the owner's profile — the
# one place a person's library is browsed.
RSpec.describe "Libraries", type: :request do
  let(:alice) { create(:coplan_user, username: "alice") }

  before { sign_in_as(alice) }

  describe "GET /library" do
    it "redirects to the current user's profile by username" do
      get my_library_path
      expect(response).to redirect_to(profile_path("alice"))
    end

  end

  describe "GET /libraries/:id" do
    it "redirects a user-owned library to its owner's profile" do
      bob = create(:coplan_user, username: "bob")
      get library_path(CoPlan::Library.for(bob))
      expect(response).to redirect_to(profile_path("bob"))
    end
  end
end
