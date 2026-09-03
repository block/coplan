# frozen_string_literal: true

# Sticky per-agent-session tokens.
#
# A token is the unit of event subscription, so each live agent wants its
# own — but "its own" has to survive the agent's own turns. An agent that
# minted a fresh token every invocation would get a new inbox and a new
# presence pill each time, and an agent that kept the token in its context
# would lose it the moment that context was compacted.
#
# So the token lives in a file keyed to the harness's session id, and the
# tools read it. The agent never sees the secret, never pastes it into a
# command line, and never has to go looking for it — which also keeps the
# whole thing out of transcripts and logs.
#
#   ~/.coplan/sessions/<session-key>.json   0600, one minted child token
#
# The parent (machine-wide, long-lived) token still comes from the
# environment. That's the only secret a human ever handles.

require "json"
require "net/http"
require "uri"
require "fileutils"
require "digest"
require "time"

module CoPlanSession
  # Leave enough runway that a token doesn't expire mid-turn.
  REFRESH_MARGIN = 5 * 60

  module_function

  def home
    File.join(ENV["COPLAN_HOME"] || File.join(Dir.home, ".coplan"), "sessions")
  end

  # Which agent run this is.
  #
  # The working directory is the default because it's the one thing that
  # reliably identifies an agent run: the usual shape is one agent per
  # checkout or worktree, and it survives context compaction, process
  # restarts, and harnesses that expose nothing about themselves. Harness
  # session ids are checked first but not depended on — Claude Code's
  # CLAUDE_SESSION_ID, for one, is not consistently exported to tool
  # subprocesses. Two agents sharing a directory should set
  # COPLAN_SESSION_KEY explicitly.
  def session_key(explicit = nil)
    key = explicit ||
      ENV["COPLAN_SESSION_KEY"] ||
      ENV["CLAUDE_SESSION_ID"] ||
      ENV["AGENT_SESSION_ID"] ||
      "cwd-#{Digest::SHA256.hexdigest(Dir.pwd)[0, 12]}"
    key.to_s.gsub(/[^A-Za-z0-9_.-]/, "_")
  end

  def path(key)
    File.join(home, "#{key}.json")
  end

  def read(key)
    JSON.parse(File.read(path(key)))
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def write(key, data)
    FileUtils.mkdir_p(home, mode: 0o700)
    File.open(path(key), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.write(JSON.pretty_generate(data))
    end
    data
  end

  def forget(key)
    File.delete(path(key))
  rescue Errno::ENOENT
    nil
  end

  def fresh?(record, base)
    return false unless record.is_a?(Hash) && record["token"]
    return false unless record["base"] == base.to_s
    return true if record["expires_at"].nil?

    Time.now + REFRESH_MARGIN < Time.parse(record["expires_at"])
  rescue ArgumentError
    false
  end

  # Returns the session token for this agent run, minting one if needed.
  # Falls back to the parent token when minting isn't available (the
  # server predates it, or the caller already holds a session token) so
  # this is always safe to call.
  def ensure_token(base:, parent:, agent_name: nil, ttl: nil, key: nil, force: false)
    key = session_key(key)
    existing = read(key)
    return existing["token"] if !force && fresh?(existing, base)

    minted = mint(base: base, parent: parent, agent_name: agent_name, ttl: ttl)
    return parent unless minted

    write(key, {
      "token" => minted["token"],
      "id" => minted["id"],
      "agent_name" => minted["agent_name"],
      "expires_at" => minted["expires_at"],
      "base" => base.to_s,
      "session_key" => key
    })["token"]
  end

  def mint(base:, parent:, agent_name: nil, ttl: nil)
    # Concatenation, not URI.join: an absolute path in URI.join discards
    # the base's mount prefix, and CoPlan engines may be mounted under one.
    uri = URI("#{base.to_s.chomp("/")}/api/v1/tokens")
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{parent}"
    req["Content-Type"] = "application/json"
    req.body = {
      agent_name: agent_name,
      name: [ agent_name, "session" ].compact.join(" "),
      ttl_seconds: ttl
    }.compact.to_json

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
    return JSON.parse(res.body) if res.code.start_with?("2")

    # 403 = the caller is already a session token; 404 = older server.
    # Either way the parent token still works, so don't fail the run.
    warn "coplan: could not mint a session token (#{res.code}); using the token as-is"
    nil
  rescue StandardError => e
    warn "coplan: could not reach #{base} to mint a session token (#{e.class}); using the token as-is"
    nil
  end

  # Revoking server-side is what actually matters; dropping the file just
  # keeps us from presenting a dead credential.
  def revoke(base:, key: nil)
    key = session_key(key)
    record = read(key)
    return false unless record

    uri = URI("#{base.to_s.chomp("/")}/api/v1/tokens/current")
    req = Net::HTTP::Delete.new(uri)
    req["Authorization"] = "Bearer #{record["token"]}"
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
    forget(key)
    true
  rescue StandardError
    forget(key)
    true
  end
end
