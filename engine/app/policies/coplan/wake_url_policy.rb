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
      !vetted_addresses(uri).nil?
    end

    # Resolve-and-vet in one step: the addresses the host resolves to,
    # iff every one of them is public; nil means refused. A caller that
    # goes on to connect must pin the connection to one of these —
    # resolving again at connect time reopens the rebinding window this
    # policy exists to close (answer the check with a public address,
    # answer the connection with a private one).
    #
    # A configured custom policy owns the whole decision and judges the
    # URI, not its addresses, so an allow comes back as :unpinned —
    # there is nothing safe to pin to.
    def vetted_addresses(uri)
      policy = CoPlan.configuration.wake_url_policy
      return (policy.call(uri) ? :unpinned : nil) if policy

      addresses = Resolv.getaddresses(uri.host.to_s)
      return nil if addresses.empty? || addresses.any? { |address| blocked_address?(address) }

      addresses
    rescue Resolv::ResolvError, Resolv::ResolvTimeout
      nil
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
