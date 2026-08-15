module CoPlan
  module Api
    module V1
      # Lets each agent run hold its own short-lived identity instead of
      # sharing a long-lived secret. Identity matters here beyond hygiene:
      # attribution rows record which agent acted, and (in the collaboration
      # work) a token is the unit of event subscription, so two agents
      # sharing one would share an inbox.
      #
      # Two ways in:
      #   - Bearer a long-lived root token (from the settings UI) to mint a
      #     child that inherits its principal.
      #   - Arrive with only the host's request auth (e.g. an mTLS proxy
      #     that names the user) and mint a session token directly. This is
      #     the one API call that works without a Bearer token — it is how
      #     an agent gets one.
      class TokensController < BaseController
        skip_before_action :require_api_token!, only: [ :create ]

        def create
          if @api_token
            unless @api_token.can_mint?
              return render json: {
                error: "Session tokens cannot mint further tokens. Use the parent token."
              }, status: :forbidden
            end
            token, raw = @api_token.mint_session_token!(
              name: params[:name],
              agent_name: params[:agent_name],
              ttl: ttl_param,
              metadata: metadata_param
            )
          else
            token, raw = ApiToken.mint_session_token_for!(
              user: current_user,
              name: params[:name],
              agent_name: params[:agent_name],
              ttl: ttl_param,
              metadata: metadata_param
            )
          end

          render json: {
            id: token.id,
            token: raw,
            name: token.name,
            agent_name: token.agent_name,
            metadata: token.metadata,
            expires_at: token.expires_at&.iso8601,
            parent_id: token.parent_id
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_content
        end

        # Self-revocation, so an agent can clean up its own token when it
        # exits rather than leaving a live credential behind until the TTL.
        def destroy
          @api_token.revoke!
          render json: { revoked: true, id: @api_token.id }
        end

        private

        def ttl_param
          (params[:ttl_seconds].presence || ApiToken::DEFAULT_SESSION_TTL.to_i).to_i
        end

        # Identity facts, schemaless by design — the model drops anything
        # that isn't hash-shaped, so no permit list to keep in sync.
        def metadata_param
          raw = params[:metadata]
          raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : raw
        end
      end
    end
  end
end
