module CoPlan
  # A delegation of a plan to an agent — one per (plan, api_token). The
  # state machine mirrors Linear's agent sessions: it drives the presence
  # pill on the plan page, so humans can see the agent is engaged the
  # moment it wakes, and whose turn it is when it asks a question.
  #
  #   pending        an event was published; the agent hasn't reacted yet
  #   active         the agent acked / is working (state_detail says what)
  #   awaiting_input the agent asked a question; it's the human's turn
  #   complete       the agent finished its turn
  #   stale          the agent never reacted to a wake — don't show a
  #                  zombie "typing…" pill
  class AgentSession < ApplicationRecord
    STATES = %w[pending active awaiting_input complete stale].freeze

    # States rendered as a live pill on the plan page.
    VISIBLE_STATES = %w[pending active awaiting_input].freeze

    # How long a session may sit in `pending` after a wake before we stop
    # promising the humans that the agent is coming.
    STALE_AFTER = 30.seconds

    belongs_to :plan, class_name: "CoPlan::Plan"
    belongs_to :api_token, class_name: "CoPlan::ApiToken"

    validates :agent_name, presence: true
    validates :state, inclusion: { in: STATES }

    scope :visible, -> { where(state: VISIBLE_STATES) }

    def transition!(new_state, detail: nil)
      update!(state: new_state, state_detail: detail, last_activity_at: Time.current)
      broadcast_pill
    end

    # Called when an event is published to this session's inbox: flip back
    # to pending (unless the agent is already mid-turn) and start the
    # stale countdown.
    def wake!
      transition!("pending") unless state == "active"
      MarkStaleAgentSessionJob.set(wait: STALE_AFTER).perform_later(
        agent_session_id: id, woken_at: last_activity_at&.iso8601 || Time.current.iso8601
      )
    end

    def display_status
      case state
      when "pending" then "#{agent_name} is on it…"
      when "active" then state_detail.presence ? "#{agent_name} is #{state_detail}" : "#{agent_name} is working…"
      when "awaiting_input" then "#{agent_name} asked a question"
      end
    end

    def broadcast_pill
      Broadcaster.replace_to(
        plan,
        target: "plan-agent-sessions",
        partial: "coplan/plans/agent_sessions",
        locals: { agent_sessions: AgentSession.visible.where(plan_id: plan_id).order(:created_at) }
      )
    end
  end
end
