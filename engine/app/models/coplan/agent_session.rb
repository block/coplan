module CoPlan
  # A delegation of a plan to an agent — one per (plan, api_token). The
  # state machine mirrors Linear's agent sessions: it drives the presence
  # pill on the plan page, so humans can see the agent is engaged the
  # moment it wakes, and whose turn it is when it asks a question.
  #
  #   watching       attached and idle — present, but not doing anything.
  #                  This is the resting state of an attached agent and
  #                  must read differently from working, or the pill lies
  #                  about activity that isn't happening.
  #   pending        an event was published; the agent hasn't reacted yet
  #   active         the agent acked / is working (state_detail says what)
  #   awaiting_input the agent asked a question; it's the human's turn
  #   complete       the agent finished its turn
  #   stale          the agent never reacted to a wake — don't show a
  #                  zombie "typing…" pill
  class AgentSession < ApplicationRecord
    STATES = %w[watching pending active awaiting_input complete stale].freeze

    # States rendered as a live pill on the plan page.
    VISIBLE_STATES = %w[watching pending active awaiting_input].freeze

    # How long a session may sit in `pending` after a wake before we stop
    # promising the humans that the agent is coming.
    STALE_AFTER = 30.seconds

    # An agent may legitimately work for a long time, but a process that
    # died mid-turn must not hold the pill forever.
    ACTIVE_STALE_AFTER = 5.minutes

    # `awaiting_input` is the human's turn, so it's allowed to sit — but
    # not past the point where the agent has certainly gone away.
    AWAITING_INPUT_STALE_AFTER = 1.hour

    # A watching agent holds an open stream, and the server touches the
    # session on every heartbeat (15s), so this only expires once the
    # connection is genuinely gone.
    WATCHING_STALE_AFTER = 2.minutes

    STALE_WINDOWS = {
      "watching" => WATCHING_STALE_AFTER,
      "pending" => STALE_AFTER,
      "active" => ACTIVE_STALE_AFTER,
      "awaiting_input" => AWAITING_INPUT_STALE_AFTER
    }.freeze

    # How recent a transport touch (SSE heartbeat every 15s, long-poll
    # park up to ~55s apart) must be to count as "a connection is parked
    # on this token right now".
    TRANSPORT_WINDOW = 90.seconds

    belongs_to :plan, class_name: "CoPlan::Plan"
    belongs_to :api_token, class_name: "CoPlan::ApiToken"

    validates :agent_name, presence: true
    validates :state, inclusion: { in: STATES }
    validate :wake_url_is_http

    # Visibility is computed at read time rather than trusting
    # MarkStaleAgentSessionJob to have run: if the job worker is down (or
    # the agent's process was killed), a `pending` row would otherwise
    # promise a ghost agent forever. The job still runs to *broadcast* the
    # removal promptly; correctness doesn't depend on it.
    scope :visible, -> {
      clauses = STALE_WINDOWS.map { "(state = ? AND COALESCE(last_activity_at, updated_at) > ?)" }.join(" OR ")
      where(clauses, *STALE_WINDOWS.flat_map { |state, window| [ state, window.ago ] })
    }

    # Is anything actually attached behind this row? Events are still
    # queued for sessions that aren't (their inbox is durable), but a
    # session with no live process must never be given a pill.
    def live?
      VISIBLE_STATES.include?(state) && !stale?
    end

    def stale?
      window = STALE_WINDOWS[state]
      return false unless window
      (last_activity_at || updated_at) <= window.ago
    end

    # Is a connection actually parked on this session's token right now?
    # The socket belongs to *some process* — it says delivery will land,
    # not that a model will act (a background curl holds a socket as well
    # as a real agent does). So this gates whether a wake is *attempted*,
    # never what the pill promises.
    def transport_connected?
      last_transport_at.present? && last_transport_at > TRANSPORT_WINDOW.ago
    end

    # Is there any path by which an event can reach something that might
    # act — a parked connection, or a registered wake URL?
    def wakeable?
      transport_connected? || wake_url.present?
    end

    # Has this session ever demonstrably turned a wake into action? Only
    # then may the pill promise one.
    def wake_proven?
      wakes_answered_count.to_i.positive?
    end

    AGENT_STATES = %w[watching active awaiting_input complete].freeze

    def transition!(new_state, detail: nil)
      # An agent-driven move out of `pending` is the one observable proof
      # that delivery became a model turn — the fact the wake promise is
      # calibrated against.
      self.wakes_answered_count += 1 if state == "pending" && AGENT_STATES.include?(new_state)
      update!(state: new_state, state_detail: detail, last_activity_at: Time.current)
      broadcast_pill
    end

    # Called when an event is published to this session's inbox: flip back
    # to pending (unless the agent is already mid-turn) and start the
    # stale countdown.
    def wake!
      transition!("pending") unless state == "active"
      # (watching → pending is correct: the agent now owes a response.)
      MarkStaleAgentSessionJob.set(wait: STALE_AFTER).perform_later(
        agent_session_id: id, woken_at: last_activity_at&.iso8601 || Time.current.iso8601
      )
    end

    def display_status
      case state
      # Listening is presence, not work: just the name. The pill's green
      # pulse carries "I'm here", so the label doesn't need a verb.
      when "watching" then agent_name
      # Delivery is not action, and wakeability can only be demonstrated,
      # never declared: a session that has answered a wake before earns
      # "Waking…"; an unproven one keeps plain presence while the wake
      # quietly tests it. "On it" is the agent's own claim to make (by
      # flipping to active).
      when "pending" then wake_proven? ? "Waking #{agent_name}…" : agent_name
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

    private

    # The server will POST to this URL, so it must at least be a URL. IP
    # allow/deny policy is the host app's concern (dev legitimately wakes
    # agents on localhost); scheme is ours.
    def wake_url_is_http
      return if wake_url.blank?

      uri = URI.parse(wake_url)
      errors.add(:wake_url, "must be an http(s) URL") unless uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      errors.add(:wake_url, "must be an http(s) URL")
    end
  end
end
