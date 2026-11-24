module Coplan
  module Settings
    class SettingsController < ApplicationController
      def index
        @agent_session_count = current_user.api_tokens.sessions.usable.count
        @personal_token_count = current_user.api_tokens.personal.active.count
        @web_push_subscriptions = current_user.web_push_subscriptions.for_delivery
        config = Coplan.configuration
        if config.ui_locales.size > 1
          @browser_locale = UiLocale.select(request.get_header("HTTP_ACCEPT_LANGUAGE"), locales: config.ui_locales, default: config.ui_default_locale)
        end
      end

      def update_language
        locales = Coplan.configuration.ui_locales
        return head :not_found unless locales.size > 1

        language = params[:language]
        if language == "" || locales.any? { |locale| locale.to_s == language }
          session[:coplan_ui_locale] = language.presence
          flash[:coplan_focus_language] = true
        else
          flash[:alert] = t("coplan.settings.language.unavailable")
        end

        redirect_to settings_root_path, status: :see_other
      end

      # Saves the light/dark mode (docs/THEMES.md).
      def update_theme
        theme = params[:theme]
        if Coplan::User::THEME_PREFERENCES.include?(theme)
          current_user.theme_preference = theme
          current_user.save!
        end
        head :ok
      end

      # Saves the app theme (docs/THEMES.md).
      def update_app_theme
        app_theme = params[:app_theme]
        if Coplan::User::APP_THEMES.include?(app_theme)
          current_user.app_theme = app_theme
          current_user.save!
          head :ok
        else
          head :unprocessable_content
        end
      end

      def update_voice_hotkey
        hotkey = params[:voice_hotkey]
        if Coplan::User::VOICE_HOTKEYS.include?(hotkey)
          current_user.voice_hotkey = hotkey
          current_user.save!
        end
        head :ok
      end
    end
  end
end
