require "net/http"
require "openssl"

module CoPlan
  # The wake path for hosted agents: POST a signed "you have inbox items"
  # ping to the URL the session registered at claim time. Deliberately a
  # ping and not a payload — the agent pulls and acks through the cursor
  # API exactly like every other transport, so at-least-once semantics
  # and the authority model don't fork, and nothing sensitive transits a
  # URL we don't control. A spurious or duplicate ping is harmless: "check
  # your inbox" is naturally idempotent, and `event_id` is there for
  # receivers that want to drop retry duplicates anyway.
  class WakeWebhookJob < ApplicationJob
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 5

    # Exhausted retry runs (not individual failed POSTs) before the URL is
    # presumed dead and unregistered. Mirrors WebPushDeliveryJob, which
    # destroys a subscription on terminal failure: a URL that has eaten
    # three full retry ladders isn't waking anyone, and every event on the
    # plan would otherwise keep hammering it forever.
    MAX_EXHAUSTIONS = 3

    # Messages must not carry the wake URL: they surface in logs and in
    # solid_queue_failed_executions, and the URL can embed a capability
    # token in its path.
    class DeliveryFailed < StandardError; end

    # A hosted platform being briefly down shouldn't cost the agent its
    # wake; a platform that's gone shouldn't be hammered forever.
    retry_on DeliveryFailed, wait: :polynomially_longer, attempts: 5 do |job, _error|
      session = AgentSession.find_by(id: job.arguments.first[:agent_session_id])
      next if session.nil? || session.wake_url.blank?

      session.wake_failures_count += 1
      if session.wake_failures_count >= MAX_EXHAUSTIONS
        session.assign_attributes(wake_url: nil, wake_secret: nil)
        Rails.logger.warn(
          "CoPlan::WakeWebhookJob: unregistered dead wake URL for agent session #{session.id} " \
          "after #{MAX_EXHAUSTIONS} exhausted delivery runs"
        )
      end
      session.save!
    end

    def perform(agent_session_id:, agent_event_id:)
      session = AgentSession.find_by(id: agent_session_id)
      return if session.nil? || session.wake_url.blank?

      event = AgentEvent.find_by(id: agent_event_id)
      return if event.nil? || event.acked_at.present? # already processed via another transport

      uri = URI.parse(session.wake_url)
      # Re-checked here, not just at registration: DNS may answer
      # differently now (rebinding), and the policy itself may have
      # changed. A refused URL is skipped, not retried — retrying can't
      # make it allowed.
      vetted = WakeUrlPolicy.vetted_addresses(uri)
      if vetted.nil?
        Rails.logger.warn("CoPlan::WakeWebhookJob: egress policy refused wake URL for agent session #{session.id}")
        return
      end

      body = {
        event_id: event.id,
        event_type: event.event_type,
        plan_id: event.plan_id,
        inbox: "/api/v1/agent/events"
      }.to_json

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["X-CoPlan-Event-Id"] = event.id
      request["X-CoPlan-Signature"] = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", session.wake_secret.to_s, body)}"
      request.body = body

      # Connect to the address the policy actually vetted (hostname still
      # drives Host/SNI/cert verification); resolving the name a second
      # time here would hand a rebinding host the connection the check
      # just refused. :unpinned (custom policy) resolves normally.
      http_options = { use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT }
      http_options[:ipaddr] = vetted.first.to_s if vetted.is_a?(Array)
      response = Net::HTTP.start(uri.hostname, uri.port, **http_options) do |http|
        http.request(request)
      end

      unless response.code.start_with?("2")
        raise DeliveryFailed, "agent session #{session.id} wake answered #{response.code}"
      end

      # The URL just proved live again; a past outage shouldn't leave it
      # one exhaustion from unregistration forever.
      session.update!(wake_failures_count: 0) if session.wake_failures_count.to_i.positive?
    rescue Timeout::Error, IOError, SystemCallError, SocketError,
           OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse => e
      # IOError covers EOFError (server closed mid-response);
      # Net::HTTPBadResponse is a bare StandardError, not a ProtocolError.
      raise DeliveryFailed, "agent session #{session.id} wake failed: #{e.class}"
    end
  end
end
