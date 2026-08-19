module CoPlan
  module Api
    module V1
      # An agent claims a session on a plan to (a) subscribe its token to
      # the plan's event inbox and (b) drive the presence pill humans see.
      #
      #   POST  /api/v1/plans/:plan_id/agent_session {"agent_name": "Claude"}
      #   PATCH /api/v1/plans/:plan_id/agent_session {"state": "active", "detail": "editing Rollout"}
      #
      # Claim states: watching / active. PATCH states: active /
      # awaiting_input / complete (pending and stale are set by the
      # server). The etiquette (mirrored from Linear's agent guidelines):
      # flip to `active` within seconds of a wake — that's the fast ack
      # humans see — then work as slowly as you need; use `awaiting_input`
      # when a question is blocking you; land on `complete` when your turn
      # is done.
      class AgentSessionsController < BaseController
        before_action :set_plan
        before_action :authorize_plan_access!

        def create
          # Claiming a session means "I'm here", not "I'm working" — an
          # attached, idle agent defaults to `watching`. Pass `state` to
          # say otherwise (the bridge claims straight into `active`).
          #
          # Only arrival states can be claimed. `awaiting_input` on a
          # session that has never done anything would park an unearned
          # "asked a question" pill for up to its hour-long stale window,
          # and `pending`/`complete`/`stale` are the server's to set.
          state = params[:state].presence || "watching"
          unless %w[watching active].include?(state)
            render json: {
              error: "state on claim must be watching or active — turn states (awaiting_input, complete) are set via PATCH once you are in the loop"
            }, status: :unprocessable_content
            return
          end

          session = AgentSession.find_or_initialize_by(plan_id: @plan.id, api_token_id: @api_token.id)
          session.agent_name = api_agent_name

          # Reattaching must not erase a question the agent is still
          # waiting on: a default claim leaves `awaiting_input` alone, so
          # the human keeps seeing whose turn it is. An explicit state wins.
          unless params[:state].blank? && session.state == "awaiting_input"
            session.state = state
            session.state_detail = params[:detail].presence
          end
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

          # `pending` (an undelivered wake) and `stale` (a wake nobody
          # answered) are verdicts the server reaches about the agent —
          # an agent reporting either about itself would be nonsense.
          state = params[:state].to_s
          unless AgentSession::STATES.include?(state) && !%w[pending stale].include?(state)
            render json: { error: "state must be one of #{(AgentSession::STATES - %w[pending stale]).join(', ')}" }, status: :unprocessable_content
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
