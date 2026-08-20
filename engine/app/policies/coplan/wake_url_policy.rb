require "ipaddr"
require "resolv"

module CoPlan
  # Egress policy for wake webhooks. The server POSTs to wake URLs its
  # users registered, which is a server-side request forgery primitive
  # unless somebody says no — so by default, no: a URL whose host
  # resolves to loopback, private, link-local (cloud metadata lives
  # there), or otherwise non-public address space is refused, both at
  # registration and again at delivery time (DNS can change its answer
  # between the two).
  #
  # Hosts with different needs — dev waking an agent on localhost, a
  # deployment that only allows an internal allowlist — override the
  # whole decision with `config.wake_url_policy = ->(uri) { ... }`.
  module WakeUrlPolicy
    BLOCKED_RANGES = %w[
      0.0.0.0/8
      10.0.0.0/8
      100.64.0.0/10
      127.0.0.0/8
      169.254.0.0/16
      172.16.0.0/12
      192.168.0.0/16
      ::/128
      ::1/128
      fc00::/7
      fe80::/10
    ].map { |range| IPAddr.new(range) }.freeze

    module_function

    def allowed?(uri)
      policy = CoPlan.configuration.wake_url_policy
      return !!policy.call(uri) if policy

      addresses = Resolv.getaddresses(uri.host.to_s)
      addresses.any? && addresses.none? { |address| blocked_address?(address) }
    rescue Resolv::ResolvError, Resolv::ResolvTimeout
      false
    end

    # Unparseable answers are refused, not excused.
    def blocked_address?(address)
      ip = IPAddr.new(address.to_s)
      BLOCKED_RANGES.any? { |range| range.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end
  end
end
