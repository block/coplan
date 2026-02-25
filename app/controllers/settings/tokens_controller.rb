module Settings
  class TokensController < ApplicationController
    before_action :scope_to_organization

    def index
      @api_tokens = current_user.api_tokens.order(created_at: :desc)
    end

    def create
      @api_token, @raw_token = ApiToken.create_with_raw_token(
        user: current_user,
        organization: @organization,
        name: params[:api_token][:name]
      )
      @api_tokens = current_user.api_tokens.order(created_at: :desc)
      flash.now[:notice] = "Token created. Copy it now — it won't be shown again."
      render :index
    rescue ActiveRecord::RecordInvalid => e
      @api_tokens = current_user.api_tokens.order(created_at: :desc)
      flash.now[:alert] = e.message
      render :index, status: :unprocessable_entity
    end

    def destroy
      token = current_user.api_tokens.find(params[:id])
      token.revoke!
      redirect_to settings_tokens_path, notice: "Token revoked."
    end
  end
end
