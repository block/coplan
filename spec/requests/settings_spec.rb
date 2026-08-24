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

  describe "PATCH /settings/voice_hotkey" do
    it "persists an allowed push-to-talk key" do
      patch settings_voice_hotkey_path, params: { voice_hotkey: "shift" }
      expect(response).to have_http_status(:ok)
      expect(alice.reload.voice_hotkey).to eq("shift")
    end

    # Nobody has a key, which is a real answer: the mic button stays and
    # the keyboard is left alone.
    it "persists turning the hotkey off" do
      patch settings_voice_hotkey_path, params: { voice_hotkey: "off" }
      expect(alice.reload.voice_hotkey).to eq("off")
    end

    it "silently ignores keys that aren't on the list" do
      patch settings_voice_hotkey_path, params: { voice_hotkey: "F13" }
      expect(response).to have_http_status(:ok)
      expect(alice.reload.voice_hotkey).to eq(CoPlan::User::DEFAULT_VOICE_HOTKEY)
    end

    # A preference nobody has set means "arrived after the setting did",
    # which reads as Ctrl+Space — the backfill gave everyone who came
    # before an explicit Shift.
    it "defaults to Ctrl+Space" do
      expect(create(:coplan_user).voice_hotkey).to eq("ctrl_space")
    end
  end
end
