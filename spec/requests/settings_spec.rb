require "rails_helper"

RSpec.describe "Settings", type: :request do
  let(:alice) { create(:coplan_user) }

  before { sign_in_as(alice) }

  describe "PATCH /settings/theme" do
    it "persists an allowed theme preference" do
      patch settings_theme_path, params: { theme: "dark" }
      expect(response).to have_http_status(:ok)
      expect(alice.reload.theme_preference).to eq("dark")
    end

    it "silently ignores unknown themes" do
      patch settings_theme_path, params: { theme: "hotdog-stand" }
      expect(response).to have_http_status(:ok)
      expect(alice.reload.theme_preference).not_to eq("hotdog-stand")
    end
  end
end
