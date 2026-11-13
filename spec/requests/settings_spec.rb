require "rails_helper"

RSpec.describe "Settings", type: :request do
  let(:alice) { create(:coplan_user) }

  before { sign_in_as(alice) }

  describe "app theme" do
    around do |example|
      original = CoPlan.configuration.default_theme
      example.run
    ensure
      CoPlan.configuration.default_theme = original
    end

    it "renders the host's default theme on <html>" do
      get settings_root_path
      expect(response.parsed_body.at_css("html")["data-app-theme"]).to eq("classic")
    end

    it "falls back to Classic when the host names an unknown theme" do
      CoPlan.configuration.default_theme = "hotdog-stand"
      get settings_root_path
      expect(response.parsed_body.at_css("html")["data-app-theme"]).to eq("classic")
    end

    it "uses the viewer's own pick over the host's default" do
      alice.update!(app_theme: "neutral")
      get settings_root_path
      expect(response.parsed_body.at_css("html")["data-app-theme"]).to eq("neutral")
      expect(response.parsed_body.at_css("html")["data-app-theme-choice"]).to eq("neutral")
    end

    it "follows a changed host default for viewers on Default" do
      CoPlan.configuration.default_theme = "neutral"
      get settings_root_path
      expect(response.parsed_body.at_css("html")["data-app-theme"]).to eq("neutral")
      expect(response.parsed_body.at_css("input[name=app_theme][value=default][checked]")).to be_present
      expect(response.body).to include("Default (Neutral)")
    end

    it "marks the theme that's showing in the bar's Appearance menu" do
      CoPlan.configuration.default_theme = "neutral"
      get settings_root_path
      menu = response.parsed_body.at_css("#appearance-menu")
      expect(menu.css("input[name=appearance_theme][checked]").map { _1["value"] }).to eq([ "neutral" ])
      expect(response.parsed_body.at_css("html")["data-app-theme-choice"]).to eq("default")
      expect(menu.css("input[name=appearance_mode][checked]").map { _1["value"] }).to eq([ alice.theme_preference ])
    end

    it "falls back to the host's default for a stored theme that no longer exists" do
      CoPlan.configuration.default_theme = "neutral"
      alice.update_column(:app_theme, "retired")
      get settings_root_path
      expect(response.parsed_body.at_css("html")["data-app-theme"]).to eq("neutral")
      expect(response.parsed_body.at_css("html")["data-app-theme-choice"]).to eq("default")
      expect(response.parsed_body.at_css("input[name=app_theme][value=default][checked]")).to be_present
    end
  end

  describe "PATCH /settings/app_theme" do
    it "persists a known theme" do
      patch settings_app_theme_path, params: { app_theme: "neutral" }
      expect(response).to have_http_status(:ok)
      expect(alice.reload.app_theme).to eq("neutral")
    end

    it "persists Default" do
      alice.update!(app_theme: "neutral")
      patch settings_app_theme_path, params: { app_theme: "default" }
      expect(response).to have_http_status(:ok)
      expect(alice.reload.app_theme).to eq("default")
    end

    it "rejects unknown themes" do
      patch settings_app_theme_path, params: { app_theme: "hotdog-stand" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(alice.reload.app_theme).to eq("default")
    end
  end

  describe "PATCH /settings/markdown_block_view" do
    it "persists a known view and puts it on the page" do
      patch settings_markdown_block_view_path, params: { markdown_block_view: "source" }
      expect(response).to have_http_status(:ok)
      expect(alice.reload.markdown_block_view).to eq("source")

      get settings_root_path
      expect(response.parsed_body.at_css("html")["data-markdown-block-view"]).to eq("source")
      expect(response.parsed_body.at_css("input[name=markdown_block_view][value=source][checked]")).to be_present
    end

    it "rejects unknown views" do
      patch settings_markdown_block_view_path, params: { markdown_block_view: "split" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(alice.reload.markdown_block_view).to eq("rendered")
    end
  end

  describe "PATCH /settings/theme" do
    it "persists an allowed theme preference" do
      patch settings_theme_path, params: { theme: "dark" }
      expect(response).to have_http_status(:ok)
      expect(alice.reload.theme_preference).to eq("dark")
      expect(alice.metadata).not_to have_key("theme_preference")
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
      expect(alice.metadata).not_to have_key("voice_hotkey")
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
