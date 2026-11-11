require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "timeout"

RSpec.describe "Local CI with parallel_tests" do
  ROOT = File.expand_path("../..", __dir__)

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      %w[bin config lib db].each { |name| FileUtils.mkdir_p(File.join(directory, name)) }
      %w[bin/ci bin/ci-db config/ci.rb lib/ci_database.rb].each { |path| FileUtils.cp(File.join(ROOT, path), File.join(directory, path)) }
      File.write(File.join(directory, "config/boot.rb"), "require 'bundler/setup'\n")
      File.write(File.join(directory, "config/database.yml"), "test:\n  adapter: mysql2\n")
      File.write(File.join(directory, "db/schema.rb"), "# fake schema\n")
      %w[rubocop bundler-audit importmap brakeman].each { |name| executable("bin/#{name}", "exit(ENV['FAIL_AUDIT'] && #{name.dump} == 'bundler-audit' ? 7 : 0)") }
      executable("bin/rails", <<~'RUBY')
        require 'json'
        name = "#{ENV.fetch('COPLAN_CI_GROUP')}-#{ENV.fetch('TEST_ENV_NUMBER')}"
        File.open("#{name}-database.jsonl", 'a') do |file|
          file.puts(JSON.generate(command:ARGV, database:ENV.fetch('COPLAN_TEST_DATABASE'), schema:ENV.fetch('SCHEMA')))
        end
        exit 3 if ENV['FAIL_SEED_DROP'] && ENV['COPLAN_CI_GROUP'] == 'seeds' && ARGV == ['db:drop']
      RUBY
      %w[models/a models/b system/a system/b].each do |name|
        path = File.join(directory, "spec/#{name}_spec.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, <<~'RUBY')
          require 'timeout'
          RSpec.describe 'CI integration' do
            it 'uses the worker environment before loading Rails' do
              group, number = ENV.values_at('COPLAN_CI_GROUP', 'TEST_ENV_NUMBER')
              expect(ENV.fetch('COPLAN_TEST_DATABASE')).to end_with("_#{group}_#{number}")
              File.write("ready-#{group}-#{number}", Process.pid)
              Timeout.timeout(10) { sleep 0.01 until Dir["ready-#{group}-*"].length == 2 }
              sleep 60 if ENV['HOLD_SPECS']
              expect(ENV['FAIL_SPEC']).to be_nil
            end
          end unless ENV['EMPTY_SPECS']
        RUBY
      end
      example.run
    end
  end

  def executable(path, source)
    file = File.join(@directory, path)
    File.write(file, "#!#{RbConfig.ruby}\n#{source}\n")
    File.chmod(0o755, file)
  end

  def run_ci(extra_env = {}, *args)
    Open3.capture3({ "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "COPLAN_CI_GROUP" => nil }.merge(extra_env),
      File.join(@directory, "bin/ci"), "--jobs", "2", "--browser-jobs", "2", *args, chdir: @directory)
  end

  def database_commands
    Dir[File.join(@directory, "*-database.jsonl")].to_h do |path|
      [ File.basename(path), File.readlines(path).map { |line| JSON.parse(line) } ]
    end
  end

  it "runs real parallel_tests workers, writes numbered reports and cleans up owned databases" do
    output, error, status = run_ci
    expect(status).to be_success, "#{output}\n#{error}"
    directory = Dir[File.join(@directory, "tmp/local-ci/*")].fetch(0)
    reports = Dir[File.join(directory, "{specs,browser}-*.json")]
    expect(reports.length).to eq(4)
    expect(reports.map { |path| JSON.parse(File.read(path)).fetch("summary").fetch("example_count") }).to eq([ 1, 1, 1, 1 ])
    rows = database_commands.values
    expect(rows.length).to eq(5)
    expect(rows.map { |entries| entries.first.fetch("database") }.uniq.length).to eq(5)
    expect(rows.map { |entries| entries.last.fetch("command") }).to all(eq([ "db:drop" ]))
    expect(File.read(File.join(@directory, "tmp/parallel_runtime_browser.log"))).to include("spec/system/")
    expect(JSON.parse(File.read(File.join(directory, "summary.json"))).values).to all(be true)
  end

  it "keeps cleanup and other pools when an audit or RSpec process fails" do
    output, error, status = run_ci({ "FAIL_SPEC" => "1", "FAIL_AUDIT" => "1" })
    expect(status).not_to be_success, "#{output}\n#{error}"
    rows = database_commands.values
    expect(rows.length).to eq(5)
    expect(rows.map { |entries| entries.last.fetch("command") }).to all(eq([ "db:drop" ]))
    directory = Dir[File.join(@directory, "tmp/local-ci/*")].fetch(0)
    summary = JSON.parse(File.read(File.join(directory, "summary.json")))
    expect(summary).to include("gem-audit" => false, "specs" => false, "browser" => false, "seeds" => true)
  end

  it "previews without starting workers or creating databases" do
    output, error, status = run_ci({}, "--list")
    expect(status).to be_success, error
    expect(output).to include("parallel_tests", "2 non-browser workers", "2 browser workers")
    expect(database_commands).to be_empty
    expect(Dir[File.join(@directory, "tmp/local-ci/*")]).to be_empty
  end

  it "rejects empty suites and reports a failed seed database cleanup" do
    output, error, status = run_ci({ "EMPTY_SPECS" => "1", "FAIL_SEED_DROP" => "1" })
    expect(status).not_to be_success, "#{output}\n#{error}"
    directory = Dir[File.join(@directory, "tmp/local-ci/*")].fetch(0)
    reports = Dir[File.join(directory, "{specs,browser}-*.json")]
    expect(reports.length).to eq(4)
    expect(reports.map { |path| JSON.parse(File.read(path)).fetch("summary").fetch("example_count") }).to eq([ 0, 0, 0, 0 ])
    summary = JSON.parse(File.read(File.join(directory, "summary.json")))
    expect(summary).to include("specs" => false, "browser" => false, "seeds" => false)
  end

  it "stops after Ctrl+C and drops the interrupted pool's databases" do
    env = { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "COPLAN_CI_GROUP" => nil, "HOLD_SPECS" => "1" }
    Open3.popen2e(env, File.join(@directory, "bin/ci"), "--jobs", "2", "--browser-jobs", "2", chdir: @directory, pgroup: true) do |input, output, wait|
      input.close
      Timeout.timeout(30) { sleep 0.01 until Dir[File.join(@directory, "ready-specs-*")].length == 2 || !wait.alive? }
      expect(wait).to be_alive, output.read unless wait.alive?
      Process.kill("INT", -wait.pid)
      status = Timeout.timeout(20) { wait.value }
      expect(status).not_to be_success
      rows = database_commands.values
      expect(rows.length).to eq(2)
      expect(rows.map { |entries| entries.last.fetch("command") }).to all(eq([ "db:drop" ]))
    ensure
      Process.kill("KILL", -wait.pid) if wait.alive?
    end
  end
end
