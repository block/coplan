require "spec_helper"
require "tmpdir"
require "stringio"
load File.expand_path("../../engine/agent_tools/coplan-connect", __dir__)

RSpec.describe CoPlanConnect::Client do
  let(:base) { "https://coplan.example.com/mounted" }
  let(:secret) { "a" * 64 }
  let(:token) { "b" * 64 }
  let(:start) do
    { "device_code" => secret, "user_code" => "ABCDE-01234",
      "verification_uri_complete" => "#{base}/_/agent/connect?user_code=ABCDE-01234",
      "interval" => 5, "expires_in" => 600 }
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @credentials = File.join(directory, "private/credentials.json")
      @output = StringIO.new
      previous = $stdout
      $stdout = @output
      example.run
    ensure
      $stdout = previous
    end
  end

  def client(**options)
    described_class.new(base: base, name: "Work laptop", credentials: @credentials, open_browser: false, **options)
  end

  it "redeems the private secret by POST and saves the credential without displaying either secret" do
    helper = client
    allow(helper).to receive(:sleep)
    expect(helper).to receive(:post).with("/api/v1/agent_connections", { name: "Work laptop" }).and_return([ start, 201 ])
    expect(helper).to receive(:post).with("/api/v1/agent_connections/token", { device_code: secret }).and_return([ { "token" => token }, 200 ])
    helper.run
    expect(JSON.parse(File.read(@credentials))).to eq("base_url" => base, "token" => token)
    expect(File.stat(@credentials).mode & 0o777).to eq(0o600)
    expect(@output.string).to include("ABCDE-01234", "Connected")
    expect(@output.string).not_to include(secret, token)
  end

  it "reuses an existing connection without minting another durable token" do
    FileUtils.mkdir_p(File.dirname(@credentials))
    File.write(@credentials, JSON.generate(base_url: base, token: token))
    helper = client
    expect(helper).not_to receive(:post)
    helper.run
    expect(@output.string).to include("Already connected")
    expect(File.stat(@credentials).mode & 0o777).to eq(0o600)
  end

  it "preserves another host's credential even when replacement was requested" do
    FileUtils.mkdir_p(File.dirname(@credentials))
    content = JSON.generate(base_url: "https://other.example.com", token: token)
    File.write(@credentials, content)
    expect { client(replace: true).run }.to raise_error(CoPlanConnect::Error, /another host/)
    expect(File.read(@credentials)).to eq(content)
  end

  it "does not save a credential after denial or expiry" do
    %w[access_denied expired_token].each do |error|
      helper = client
      allow(helper).to receive(:sleep)
      allow(helper).to receive(:post).with("/api/v1/agent_connections", anything).and_return([ start, 201 ])
      allow(helper).to receive(:post).with("/api/v1/agent_connections/token", anything).and_return([ { "error" => error }, 400 ])
      expect { helper.run }.to raise_error(CoPlanConnect::Error)
      expect(File.exist?(@credentials)).to be false
    end
  end

  it "backs off on pending or throttled requests" do
    helper = client
    allow(helper).to receive(:post).with("/api/v1/agent_connections", anything).and_return([ start, 201 ])
    allow(helper).to receive(:post).with("/api/v1/agent_connections/token", anything).and_return(
      [ { "error" => "authorization_pending" }, 400 ], [ { "error" => "slow_down" }, 400 ], [ { "token" => token }, 200 ])
    expect(helper).to receive(:sleep).with(5).twice.ordered
    expect(helper).to receive(:sleep).with(10).ordered
    helper.run
    expect(File.exist?(@credentials)).to be true
  end

  it "rejects approval links to another origin" do
    helper = client
    allow(helper).to receive(:post).and_return([ start.merge("verification_uri_complete" => "https://other.example.com"), 201 ])
    expect { helper.run }.to raise_error(CoPlanConnect::Error, /approval URL/)
    expect(File.exist?(@credentials)).to be false
  end

  it "rejects insecure URLs except loopback and rejects URLs with embedded credentials" do
    %w[http://coplan.example.com https://user:password@coplan.example.com https://coplan.example.com?token=secret].each do |url|
      expect { described_class.new(base: url, name: "Laptop", credentials: @credentials) }.to raise_error(CoPlanConnect::Error)
    end
    expect { described_class.new(base: "http://localhost:3116", name: "Laptop", credentials: @credentials) }.not_to raise_error
  end

  it "refuses credentials symlinks without overwriting their targets" do
    target = File.join(File.dirname(File.dirname(@credentials)), "other-file")
    File.write(target, "preserve")
    FileUtils.mkdir_p(File.dirname(@credentials))
    File.symlink(target, @credentials)
    expect { client.run }.to raise_error(CoPlanConnect::Error, /symbolic link/)
    expect(File.read(target)).to eq("preserve")
  end
end

RSpec.describe CoPlanConnect do
  it "does not expose response contents through JSON parse errors" do
    allow(CoPlanConnect::Client).to receive(:new).and_raise(JSON::ParserError, "sensitive-response-value")
    expect { expect(described_class.run([ "--base", "https://example.com" ])).to eq(1) }
      .to output("Connection setup failed (JSON::ParserError). No credential was printed.\n").to_stderr
  end
end
