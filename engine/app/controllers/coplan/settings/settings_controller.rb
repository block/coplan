module CoPlan
  module Settings
    class SettingsController < ApplicationController
      def index
        @api_tokens = current_user.api_tokens.order(created_at: :desc) if show_api_tokens?
      end
    end
  end
end
