module CoPlan
  module Api
    module V1
      # Lets a machine keep one long-lived token and hand each agent run its
      # own short-lived identity, minted over the API instead of clicked out
      # of the settings UI. Identity matters here beyond hygiene: a token is
      # the unit of event subscription, so two agents sharing one token share
      # an inbox and steal each other's wakes.
      class TokensController < BaseController
        # Minting is a token-holder operation; a browser session has the
        # settings UI for this and no parent token to mint from.
        before_action :require_token_auth!

        def create
          unless @api_token.can_mint?
            return render json: {
              error: "Session tokens cannot mint further tokens. Use the parent token."
            }, status: :forbidden
          end

          ttl = (params[:ttl_seconds].presence || ApiToken::DEFAULT_SESSION_TTL.to_i).to_i
          token, raw = @api_token.mint_session_token!(
            name: params[:name],
            agent_name: params[:agent_name],
            ttl: ttl
          )

          render json: {
            id: token.id,
            token: raw,
            name: token.name,
            agent_name: token.agent_name,
            expires_at: token.expires_at&.iso8601,
            parent_id: token.parent_id
          }, status: :created
        end

        # Self-revocation, so an agent can clean up its own token when it
        # exits rather than leaving a live credential behind until the TTL.
        def destroy
          @api_token.revoke!
          render json: { revoked: true, id: @api_token.id }
        end

        private

        def require_token_auth!
          return if @api_token
          render json: { error: "This endpoint requires an API token." }, status: :forbidden
        end
      end
    end
  end
end
