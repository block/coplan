module CoPlan
  module Settings
    class SettingsController < ApplicationController
      def index
        @api_tokens = current_user.api_tokens.order(created_at: :desc)
      end

      def update_theme
        theme = params[:theme]
        if CoPlan::User::THEME_PREFERENCES.include?(theme)
          current_user.theme_preference = theme
          current_user.save!
        end
        head :ok
      end
    end
  end
end
