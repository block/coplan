require "spec_helper"
require "tmpdir"
require "rbconfig"
require "open3"
require "timeout"
require_relative "../../lib/local_ci"

RSpec.describe LocalCi do
  around do |example|
    original = ENV.to_h.slice("DATABASE_URL", "SCHEMA", "COPLAN_TEST_DATABASE")
    ENV.delete("DATABASE_URL")
    Dir.mktmpdir do |directory|
      @directory = directory
      example.run
    end
  ensure
    %w[DATABASE_URL SCHEMA COPLAN_TEST_DATABASE].each { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
  end

  def runner(jobs: 2)
    described_class.new(jobs: jobs, browser_jobs: 1, seed: 123).tap do |ci|
      ci.instance_variable_set(:@directory, @directory)
    end
  end

  def task(name, source, report: nil)
    described_class::Task.new(name: name, env: {}, report: report,
      commands: [ [ RbConfig.ruby, "-e", source ] ])
  end

  it "includes every spec exactly once and keeps browser shards separate" do
    ci = runner(jobs: 4)
    commands = ci.tasks.flat_map(&:commands)
    selected = commands.flatten.select { |arg| arg.end_with?("_spec.rb") }
    expect(selected.sort).to eq(Dir["spec/**/*_spec.rb"].sort)
    expect(ci.tasks.select { |item| item.name.start_with?("browser-") }.flat_map(&:commands).flatten.grep(/_spec\.rb$/)).to all(start_with("spec/system/"))
    expect(ci.tasks.select { |item| item.name.start_with?("specs-") }.flat_map(&:commands).flatten.grep(/_spec\.rb$/)).not_to include(start_with("spec/system/"))
  end

  it "uses different databases and schema files for every worker and invocation" do
    first = runner.tasks.select(&:database)
    second = runner.tasks.select(&:database)
    databases = (first + second).map(&:database)
    expect(databases.uniq).to eq(databases)
    expect(first.map { |item| item.env.fetch("SCHEMA") }.uniq.length).to eq(first.length)
    expect(first.map { |item| item.env.fetch("RAILS_ENV") }).to all(eq("test"))
    expect(first.map(&:database)).not_to include("coplan_test", "coplan_development")
  end

  it "preserves URL connection options while replacing every database selector" do
    ENV["DATABASE_URL"] = "postgresql://test-user@localhost:5433/shared?encoding=unicode&database=shared&sslmode=require"
    ci = runner
    ci.tasks.select(&:database).each do |item|
      url = URI.parse(item.env.fetch("DATABASE_URL"))
      expect(url.path).to eq("/#{item.database}")
      expect(url.userinfo).to eq("test-user")
      expect(url.port).to eq(5433)
      expect(URI.decode_www_form(url.query).to_h).to eq("encoding" => "unicode", "sslmode" => "require")
    end
  end

  it "runs workers concurrently and waits for every result after a failure" do
    ci = runner
    # Each process must see its sibling before it can finish. A sequential
    # implementation fails the deadline instead of silently passing this test.
    source = <<~RUBY
      require 'timeout'
      File.write(File.join(#{@directory.dump}, ARGV.fetch(0)), '')
      Timeout.timeout(5) do
        sleep 0.01 until Dir[File.join(#{@directory.dump}, 'ready-*')].length == 2
      end
    RUBY
    first = task("first", source)
    first.commands.first.concat([ "ready-first" ])
    second = task("second", source)
    second.commands.first.concat([ "ready-second" ])
    ci.tasks.replace([ first, second, task("failed", "exit 7"), task("last", "puts 'still ran'") ])
    expect(ci.run).to be false
    expect(JSON.parse(File.read(File.join(@directory, "summary.json")))).to eq(
      "first" => true, "second" => true, "failed" => false, "last" => true)
    expect(File.read(File.join(@directory, "last.log"))).to include("still ran")
  end

  it "rejects an empty suite or missing report even when RSpec exits zero" do
    ci = runner
    report = File.join(@directory, "empty.json")
    File.write(report, JSON.generate(summary: { example_count: 0, failure_count: 0 }))
    ci.tasks.replace([ task("empty", "exit 0", report: report), task("missing", "exit 0", report: "#{report}.missing") ])
    expect(ci.run).to be false
    expect(JSON.parse(File.read(File.join(@directory, "summary.json"))).values).to eq([ false, false ])
  end

  it "cleans up a database after setup fails and never runs its specs" do
    ci = runner(jobs: 1)
    item = ci.tasks.find(&:database)
    item.env["SCHEMA"] = File.join(@directory, "schema.rb")
    ci.tasks.replace([ item ])
    commands = []
    allow(ci).to receive(:command) do |_task, args, _log, **_options|
      commands << args
      args.include?("db:drop")
    end
    expect(ci.run).to be false
    expect(commands.map(&:last)).to eq([ "db:schema:load", "db:drop" ])
  end

  it "fails when database cleanup fails" do
    ci = runner(jobs: 1)
    item = ci.tasks.last # The seed check has no RSpec report to fake.
    item.env["SCHEMA"] = File.join(@directory, "schema.rb")
    ci.tasks.replace([ item ])
    allow(ci).to receive(:command) { |_task, args, _log, **_options| !args.include?("db:drop") }
    expect(ci.run).to be false
  end

  it "rejects invalid worker counts before starting commands" do
    expect { described_class.start([ "--jobs", "0" ]) }.to raise_error(SystemExit)
    expect { described_class.start([ "--jobs", "2", "--browser-jobs", "3" ]) }.to raise_error(SystemExit)
  end

  it "stops child processes and exits unsuccessfully on interruption" do
    started = File.join(@directory, "child.pid")
    source = <<~RUBY
      require #{File.expand_path('../../lib/local_ci', __dir__).dump}
      ci = LocalCi.new(jobs: 1, browser_jobs: 1, seed: 123)
      ci.instance_variable_set(:@directory, #{@directory.dump})
      child = "File.write(ARGV.fetch(0), Process.pid); sleep 60"
      ci.tasks.replace([LocalCi::Task.new(name: 'interrupted', env: {}, commands: [[#{RbConfig.ruby.dump}, '-e', child, #{started.dump}]])])
      exit(ci.run ? 0 : 1)
    RUBY
    # Keep the signal inside a subprocess so RSpec's own handlers are untouched.
    Open3.popen2e(RbConfig.ruby, "-e", source) do |input, output, wait|
      input.close
      Timeout.timeout(10) { sleep 0.01 until File.exist?(started) || !wait.alive? }
      expect(wait).to be_alive, output.read unless wait.alive?
      Process.kill("INT", wait.pid)
      status = Timeout.timeout(15) { wait.value }
      expect(status.exitstatus).to eq(1), output.read
      expect { Process.kill(0, Integer(File.read(started))) }.to raise_error(Errno::ESRCH)
      expect(File.read(File.join(@directory, "summary.json"))).to include('"interrupted"')
    ensure
      Process.kill("KILL", wait.pid) if wait.alive?
    end
  end
end
