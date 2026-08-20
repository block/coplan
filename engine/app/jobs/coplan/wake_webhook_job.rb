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

    class DeliveryFailed < StandardError; end

    # A hosted platform being briefly down shouldn't cost the agent its
    # wake; a platform that's gone shouldn't be hammered forever.
    retry_on DeliveryFailed, wait: :polynomially_longer, attempts: 5

    def perform(agent_session_id:, agent_event_id:)
      session = AgentSession.find_by(id: agent_session_id)
      return if session.nil? || session.wake_url.blank?

      event = AgentEvent.find_by(id: agent_event_id)
      return if event.nil? || event.acked_at.present? # already processed via another transport

      body = {
        event_id: event.id,
        event_type: event.event_type,
        plan_id: event.plan_id,
        inbox: "/api/v1/agent/events"
      }.to_json

      uri = URI.parse(session.wake_url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["X-CoPlan-Event-Id"] = event.id
      request["X-CoPlan-Signature"] = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", session.wake_secret.to_s, body)}"
      request.body = body

      response = Net::HTTP.start(uri.hostname, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end

      raise DeliveryFailed, "#{session.wake_url} answered #{response.code}" unless response.code.start_with?("2")
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
      raise DeliveryFailed, "#{session.wake_url}: #{e.class}"
    end
  end
end
