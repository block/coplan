module CoPlan
  module Settings
    class SettingsController < ApplicationController
      def index
        @agent_session_count = current_user.api_tokens.sessions.usable.count
        @personal_token_count = current_user.api_tokens.personal.active.count
        @web_push_subscriptions = current_user.web_push_subscriptions.order(created_at: :desc)
      end

      def update_theme
        theme = params[:theme]
        if CoPlan::User::THEME_PREFERENCES.include?(theme)
          current_user.theme_preference = theme
          current_user.save!
        end
        head :ok
      end

      def update_voice_hotkey
        hotkey = params[:voice_hotkey]
        if CoPlan::User::VOICE_HOTKEYS.include?(hotkey)
          current_user.voice_hotkey = hotkey
          current_user.save!
        end
        head :ok
      end
    end
  end
end
