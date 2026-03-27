module CoPlan
  module Settings
    class TokensController < ApplicationController
      def index
        @api_tokens = current_user.api_tokens.order(created_at: :desc)
      end

      def create
        @api_token, @raw_token = ApiToken.create_with_raw_token(user: current_user, name: params[:api_token][:name])
        @api_tokens = current_user.api_tokens.order(created_at: :desc)

        respond_to do |format|
          format.turbo_stream
          format.html do
            flash[:raw_token] = @raw_token
            flash[:notice] = "Token created. Copy it now — it won't be shown again."
            redirect_to settings_tokens_path, status: :see_other
          end
        end
      rescue ActiveRecord::RecordInvalid => e
        @api_tokens = current_user.api_tokens.order(created_at: :desc)
        flash.now[:alert] = e.message
        render :index, status: :unprocessable_content
      end

      def destroy
        @token = current_user.api_tokens.find(params[:id])
        @token.revoke!

        respond_to do |format|
          format.turbo_stream
          format.html { redirect_to settings_tokens_path, notice: "Token revoked.", status: :see_other }
        end
      end
    end
  end
end
