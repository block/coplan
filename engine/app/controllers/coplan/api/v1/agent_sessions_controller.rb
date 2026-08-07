module CoPlan
  module Api
    module V1
      # An agent claims a session on a plan to (a) subscribe its token to
      # the plan's event inbox and (b) drive the presence pill humans see.
      #
      #   POST  /api/v1/plans/:plan_id/agent_session {"agent_name": "Claude"}
      #   PATCH /api/v1/plans/:plan_id/agent_session {"state": "active", "detail": "editing Rollout"}
      #
      # States: pending / active / awaiting_input / complete (stale is set
      # by the server, not the agent). The etiquette (mirrored from
      # Linear's agent guidelines): flip to `active` within seconds of a
      # wake — that's the fast ack humans see — then work as slowly as you
      # need; use `awaiting_input` when a question is blocking you; land on
      # `complete` when your turn is done.
      class AgentSessionsController < BaseController
        before_action :set_plan
        before_action :authorize_plan_access!
        before_action :require_token!

        def create
          session = AgentSession.find_or_initialize_by(plan_id: @plan.id, api_token_id: @api_token.id)
          session.agent_name = params[:agent_name].presence || @api_token.agent_name.presence || @api_token.name
          session.state = "active"
          session.last_activity_at = Time.current
          session.save!
          session.broadcast_pill

          render json: session_json(session), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_content
        end

        def update
          session = AgentSession.find_by(plan_id: @plan.id, api_token_id: @api_token.id)
          unless session
            render json: { error: "No agent session on this plan — POST to create one" }, status: :not_found
            return
          end

          state = params[:state].to_s
          unless AgentSession::STATES.include?(state) && state != "stale"
            render json: { error: "state must be one of #{(AgentSession::STATES - ['stale']).join(', ')}" }, status: :unprocessable_content
            return
          end

          session.transition!(state, detail: params[:detail].presence)
          render json: session_json(session)
        end

        def destroy
          session = AgentSession.find_by(plan_id: @plan.id, api_token_id: @api_token.id)
          session&.transition!("complete")
          session&.destroy!
          head :no_content
        end

        private

        def require_token!
          return if @api_token

          render json: { error: "Agent sessions require token authentication" }, status: :forbidden
        end

        def session_json(session)
          {
            id: session.id,
            plan_id: session.plan_id,
            agent_name: session.agent_name,
            state: session.state,
            state_detail: session.state_detail,
            last_activity_at: session.last_activity_at
          }
        end
      end
    end
  end
end
