require "digest"
require "erb"
require "fileutils"
require "uri"
require "yaml"

# The only project-specific parallel_tests setup: fresh database/schema names.
class CiDatabase
  attr_reader :env, :postgres

  def initialize(source = ENV)
    directory = source.fetch("COPLAN_CI_DIRECTORY")
    group = source.fetch("COPLAN_CI_GROUP")
    number = source.fetch("TEST_ENV_NUMBER")
    raise ArgumentError, "Invalid CI worker" unless group.match?(/\A(?:specs|browser|seeds)\z/) && number.match?(/\A[1-9]\d*\z/)
    database = "coplan_ci_#{Digest::SHA256.hexdigest(directory)[0, 12]}_#{group}_#{number}"
    config = YAML.safe_load(ERB.new(File.read("config/database.yml")).result, aliases: true).fetch("test")
    url = URI.parse(source.fetch("DATABASE_URL")) if source["DATABASE_URL"]
    adapter = url ? url.scheme : config.fetch("adapter")
    raise ArgumentError, "Local CI supports mysql2 and PostgreSQL databases" unless %w[mysql2 postgres postgresql].include?(adapter)
    @postgres = %w[postgres postgresql].include?(adapter)
    @env = { "RAILS_ENV" => "test", "COPLAN_TEST_DATABASE" => database, "SCHEMA" => File.join(directory, "#{group}-#{number}-schema.rb") }
    if url
      url.path = "/#{database}"
      params = URI.decode_www_form(url.query || "").reject { |key, _| key == "database" }
      params << [ "encoding", "unicode" ] if postgres && params.none? { |key, _| key == "encoding" }
      url.query = params.empty? ? nil : URI.encode_www_form(params)
      @env["DATABASE_URL"] = url.to_s
    end
  end

  def prepare
    FileUtils.mkdir_p(File.dirname(env.fetch("SCHEMA")))
    FileUtils.cp("db/schema.rb", env.fetch("SCHEMA")) unless postgres
    [ "db:create", postgres ? "db:migrate" : "db:schema:load" ]
  end
end

# parallel_rspec loads this before rails_helper, using its TEST_ENV_NUMBER.
ENV.update(CiDatabase.new.env) if ENV["COPLAN_CI_GROUP"]
