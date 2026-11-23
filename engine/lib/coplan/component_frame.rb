module CoPlan
  # A fixed Rack response deliberately outside host authentication, templates,
  # Turbo and session callbacks. No plan bytes or request parameters enter it.
  class ComponentFrame
    SHELL = File.read(File.join(__dir__, "components/frame.html")).sub("/* SNAPSHOT_HELPER */") { File.read(File.join(__dir__, "components/snapshot.js")) }.freeze

    def self.call(_env)
      return [ 404, { "cache-control" => "no-store" }, [] ] unless CoPlan.configuration.components_enabled

      nonce = SecureRandom.base64(24)
      policy = [
        "sandbox allow-scripts", "default-src 'none'", "base-uri 'none'", "form-action 'none'",
        "frame-ancestors 'self'", "script-src 'nonce-#{nonce}' blob:", "style-src 'unsafe-inline'",
        "img-src data: blob:", "connect-src 'none'", "webrtc 'block'", "worker-src 'none'", "frame-src 'none'"
      ].join("; ")
      headers = { "content-type" => "text/html; charset=utf-8", "content-security-policy" => policy,
        "connection-allowlist" => "()", "referrer-policy" => "no-referrer", "cache-control" => "no-store",
        "permissions-policy" => "camera=(), microphone=(), geolocation=(), display-capture=(), payment=(), usb=()" }
      [ 200, headers, [ SHELL.sub("COMPONENT_SCRIPT_NONCE", nonce) ] ]
    end
  end
end
