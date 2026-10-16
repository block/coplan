require "spec_helper"
require "tmpdir"
require_relative "../../engine/agent_tools/coplan_session"

RSpec.describe CoPlanSession do
  around do |example|
    keys = %w[COPLAN_HARNESS COPLAN_HARNESS_VERSION COPLAN_MODEL COPLAN_HOME]
    previous = ENV.to_h.slice(*keys)
    Dir.mktmpdir do |directory|
      ENV["COPLAN_HOME"] = directory
      ENV["COPLAN_HARNESS"] = "codex"
      ENV["COPLAN_HARNESS_VERSION"] = "test-version"
      ENV["COPLAN_MODEL"] = "test-model"
      example.run
    end
  ensure
    keys.each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  it "passes reported harness identity when minting and reuses the cached session" do
    response = double(code: "201", body: { token: "session-secret", expires_at: (Time.now + 3600).iso8601 }.to_json)
    http = double
    allow(Net::HTTP).to receive(:start).and_yield(http)
    expect(http).to receive(:request).once do |request|
      expect(request.path).to eq("/coplan/api/v1/tokens")
      expect(JSON.parse(request.body).fetch("metadata")).to eq(
        "harness" => "codex", "harness_version" => "test-version", "model" => "test-model")
      response
    end
    twice = 2.times.map { described_class.ensure_token(base: "https://example.com/coplan", parent: "parent-secret", key: "one-run") }
    expect(twice).to eq(%w[session-secret session-secret])
  end

  it "lets callers supply identity without replacing it with environment values" do
    response = double(code: "201", body: { token: "session-secret" }.to_json)
    http = double
    allow(Net::HTTP).to receive(:start).and_yield(http)
    expect(http).to receive(:request) do |request|
      expect(JSON.parse(request.body).fetch("metadata")).to eq("harness" => "amp")
      response
    end
    described_class.mint(base: "https://example.com", parent: "parent-secret", metadata: { harness: "amp" })
  end
end
