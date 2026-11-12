require "spec_helper"
require_relative "../../lib/ci_database"

RSpec.describe CiDatabase do
  let(:source) { { "COPLAN_CI_DIRECTORY" => "/tmp/coplan-ci-example", "COPLAN_CI_GROUP" => "specs", "TEST_ENV_NUMBER" => "1" } }

  it "keeps workers, cohorts and concurrent invocations in different databases" do
    inputs = [ source, source.merge("TEST_ENV_NUMBER" => "2"), source.merge("COPLAN_CI_GROUP" => "browser"),
      source.merge("COPLAN_CI_DIRECTORY" => "/tmp/coplan-ci-other") ]
    configs = inputs.map { |input| described_class.new(input).env }
    expect(configs.map { |env| env.fetch("COPLAN_TEST_DATABASE") }.uniq.length).to eq(4)
    expect(configs.map { |env| env.fetch("SCHEMA") }.uniq.length).to eq(4)
    expect(configs.map { |env| env.fetch("RAILS_ENV") }).to all(eq("test"))
  end

  it "replaces URL database selectors without changing the connection" do
    config = described_class.new(source.merge("DATABASE_URL" => "postgresql://test-user@localhost:5433/shared?database=shared&sslmode=require"))
    url = URI.parse(config.env.fetch("DATABASE_URL"))
    expect(url.path).to eq("/#{config.env.fetch('COPLAN_TEST_DATABASE')}")
    expect([ url.user, url.host, url.port ]).to eq([ "test-user", "localhost", 5433 ])
    expect(URI.decode_www_form(url.query).to_h).to eq("sslmode" => "require", "encoding" => "unicode")
    expect(config.postgres).to be true
  end

  it "rejects missing or invalid worker numbers rather than using a shared database" do
    [ "", "0", "../shared" ].each do |number|
      expect { described_class.new(source.merge("TEST_ENV_NUMBER" => number)) }.to raise_error(ArgumentError)
    end
    expect { described_class.new(source.merge("COPLAN_CI_GROUP" => "development")) }.to raise_error(ArgumentError)
  end
end
