require "rails_helper"

RSpec.describe "Settings", type: :request do
  let(:alice) { create(:coplan_user) }

  before { sign_in_as(alice) }

  describe "UI language" do
    it "hides the language picker and rejects overrides when the host enables one language" do
      get settings_root_path
      expect(response.parsed_body.at_css("#settings-language-choice")).to be_nil
      patch settings_language_path, params: { language: "es" }
      expect(response).to have_http_status(:not_found)
    end

    context "when the host enables English and Spanish" do
      before do
        allow(Coplan.configuration).to receive(:ui_locales).and_return(%i[en es])
      end

      it "applies the selection across pages and restores browser matching when cleared" do
        headers = { "Accept-Language" => "en-US" }
        patch settings_language_path, params: { language: "es" }, headers: headers
        expect(response).to redirect_to(settings_root_path)
        follow_redirect!(headers: headers)
        expect(response.headers["Content-Language"]).to eq("es")
        expect(response.headers["Vary"]).to include("Accept-Language", "Cookie")
        browser_option = response.parsed_body.at_css('#settings-language-choice option[value=""]')
        expect(browser_option.text).to eq("Browser language (English)")
        expect(browser_option["lang"]).to eq("en")
        expect(response.parsed_body.at_css('#settings-language-choice option[selected]')["value"]).to eq("es")
        get search_path, headers: headers
        expect(response.body).to include("Buscar planes y personas")

        patch settings_language_path, params: { language: "" }, headers: headers
        follow_redirect!(headers: headers)
        expect(response.headers["Content-Language"]).to eq("en")
        get search_path, headers: { "Accept-Language" => "es-MX" }
        expect(response.headers["Content-Language"]).to eq("es")
      end

      it "shows the browser match in that language even while English is selected" do
        patch settings_language_path, params: { language: "en" }
        get settings_root_path, headers: { "Accept-Language" => "es-MX, en;q=0.8" }

        expect(response.headers["Content-Language"]).to eq("en")
        option = response.parsed_body.at_css('#settings-language-choice option[value=""]')
        expect(option.text).to eq("Idioma del navegador (Español)")
        expect(option["lang"]).to eq("es")
      end

      it "shows the site fallback when the browser's languages are unavailable" do
        allow(Coplan.configuration).to receive(:ui_default_locale).and_return("en")
        get settings_root_path, headers: { "Accept-Language" => "fr-CA, fr;q=0.8" }

        expect(response.headers["Content-Language"]).to eq("en")
        expect(response.parsed_body.at_css('#settings-language-choice option[value=""]').text).to eq("Browser language (English)")
      end

      it "rejects unsupported choices and preserves the current selection" do
        patch settings_language_path, params: { language: "es" }
        patch settings_language_path, params: { language: "fr" }
        follow_redirect!
        expect(response.headers["Content-Language"]).to eq("es")
        expect(response.body).to include("Ese idioma ya no está disponible.")
      end
    end
  end

  describe "app theme" do
    around do |example|
      original = Coplan.configuration.default_theme
      example.run
    ensure
      Coplan.configuration.default_theme = original
    end

    it "renders the host's default theme on <html>" do
      get settings_root_path
      expect(response.parsed_body.at_css("html")["data-app-theme"]).to eq("classic")
    end

    it "falls back to Classic when the host names an unknown theme" do
      Coplan.configuration.default_theme = "hotdog-stand"
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
      Coplan.configuration.default_theme = "neutral"
      get settings_root_path
      expect(response.parsed_body.at_css("html")["data-app-theme"]).to eq("neutral")
      expect(response.parsed_body.at_css("input[name=app_theme][value=default][checked]")).to be_present
      expect(response.body).to include("Default (Neutral)")
    end

    it "marks the theme that's showing in the bar's Appearance menu" do
      Coplan.configuration.default_theme = "neutral"
      get settings_root_path
      menu = response.parsed_body.at_css("#appearance-menu")
      expect(menu.css("input[name=appearance_theme][checked]").map { _1["value"] }).to eq([ "neutral" ])
      expect(response.parsed_body.at_css("html")["data-app-theme-choice"]).to eq("default")
      expect(menu.css("input[name=appearance_mode][checked]").map { _1["value"] }).to eq([ alice.theme_preference ])
    end

    it "falls back to the host's default for a stored theme that no longer exists" do
      Coplan.configuration.default_theme = "neutral"
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
      expect(alice.reload.voice_hotkey).to eq(Coplan::User::DEFAULT_VOICE_HOTKEY)
    end

    # A preference nobody has set means "arrived after the setting did",
    # which reads as Ctrl+Space — the backfill gave everyone who came
    # before an explicit Shift.
    it "defaults to Ctrl+Space" do
      expect(create(:coplan_user).voice_hotkey).to eq("ctrl_space")
    end
  end
end
