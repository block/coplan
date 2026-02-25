module Api
  module V1
    class SessionsController < BaseController
      before_action :set_plan
      before_action :authorize_plan_access!
      before_action :set_session, only: [:show, :commit]

      # POST /api/v1/plans/:plan_id/sessions
      # Cloud personas create sessions via direct Ruby service calls, not this endpoint.
      def create
        actor_type = params[:actor_type].presence || ApiToken::HOLDER_TYPE
        unless EditSession::ACTOR_TYPES.include?(actor_type)
          render json: { error: "Invalid actor_type" }, status: :unprocessable_entity
          return
        end
        ttl = actor_type == "cloud_persona" ? EditSession::CLOUD_PERSONA_TTL : EditSession::LOCAL_AGENT_TTL

        session = EditSession.create!(
          plan: @plan,
          organization: current_organization,
          actor_type: actor_type,
          actor_id: @api_token.id,
          base_revision: @plan.current_revision,
          expires_at: ttl.from_now
        )

        render json: session_json(session), status: :created
      end

      # GET /api/v1/plans/:plan_id/sessions/:id
      def show
        render json: session_json(@session).merge(
          operations_count: @session.operations_json.length,
          has_draft: @session.draft_content.present?
        )
      end

      # POST /api/v1/plans/:plan_id/sessions/:id/commit
      def commit
        result = Plans::CommitSession.call(
          session: @session,
          change_summary: params[:change_summary]
        )

        response = {
          session_id: @session.id,
          status: @session.status,
          committed_at: @session.committed_at
        }

        if result[:version]
          response[:revision] = result[:version].revision
          response[:version_id] = result[:version].id
          response[:content_sha256] = result[:version].content_sha256
        end

        render json: response
      rescue Plans::CommitSession::SessionNotOpenError => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue Plans::CommitSession::StaleSessionError => e
        render json: { error: e.message }, status: :conflict
      rescue Plans::CommitSession::SessionConflictError => e
        render json: {
          error: e.message,
          current_revision: @plan.reload.current_revision
        }, status: :conflict
      end

      private

      def set_session
        @session = @plan.edit_sessions.find_by(id: params[:id])
        unless @session
          render json: { error: "Edit session not found" }, status: :not_found
        end
      end

      def session_json(session)
        {
          id: session.id,
          plan_id: session.plan_id,
          status: session.status,
          actor_type: session.actor_type,
          base_revision: session.base_revision,
          expires_at: session.expires_at,
          created_at: session.created_at
        }
      end
    end
  end
end
