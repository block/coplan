require "digest"
require "erb"
require "etc"
require "fileutils"
require "json"
require "optparse"
require "securerandom"
require "thread"
require "uri"
require "yaml"
require_relative "../config/ci"

# Local tooling only: never boot Rails in the coordinator or share a test DB.
class LocalCi
  Task = Struct.new(:name, :commands, :env, :database, :report, keyword_init: true)

  def self.start(arguments)
    options = { jobs: [ [ Etc.nprocessors / 2, 1 ].max, 8 ].min, seed: Random.new_seed % 65536 }
    parser = OptionParser.new do |args|
      args.banner = "Usage: bin/ci [--jobs N] [--browser-jobs N] [--seed N] [--list]"
      args.on("--jobs N", Integer, "Maximum simultaneous checks (default: half the CPUs, up to 8)") { |n| options[:jobs] = n }
      args.on("--browser-jobs N", Integer, "Browser shards (default: up to 4)") { |n| options[:browser_jobs] = n }
      args.on("--seed N", Integer, "RSpec random-order seed") { |n| options[:seed] = n }
      args.on("--list", "Show the plan without running commands or creating databases") { options[:list] = true }
      args.on("-h", "--help") { puts args; return }
    end
    parser.parse!(arguments)
    raise OptionParser::InvalidArgument, arguments.join(" ") unless arguments.empty?
    options[:browser_jobs] ||= [ options[:jobs], 4 ].min
    unless options[:jobs].positive? && options[:browser_jobs].between?(1, options[:jobs])
      raise OptionParser::InvalidArgument, "jobs must be positive; browser-jobs must be between 1 and jobs"
    end
    list = options.delete(:list)
    runner = new(**options)
    if list
      runner.describe
    else
      exit(runner.run ? 0 : 1)
    end
  rescue OptionParser::ParseError, ArgumentError => error
    abort error.message
  end

  # Greedy file-size balancing avoids putting every large browser spec together.
  def self.shards(files, count)
    groups = Array.new([ files.length, count ].min) { [] }
    sizes = groups.to_h { |group| [ group.object_id, 0 ] }
    files.sort_by { |file| [ -File.size(file), file ] }.each do |file|
      group = groups.min_by { |candidate| sizes.fetch(candidate.object_id) }
      group << file
      sizes[group.object_id] += File.size(file)
    end
    groups
  end

  attr_reader :tasks, :directory

  def initialize(jobs:, browser_jobs:, seed:)
    @jobs, @seed = jobs, seed
    @directory = File.expand_path("tmp/local-ci/#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}-#{SecureRandom.hex(3)}")
    @mutex, @children, @results = Mutex.new, {}, {}
    @interrupted = false
    database_config = YAML.safe_load(ERB.new(File.read("config/database.yml")).result, aliases: true).fetch("test")
    adapter = ENV["DATABASE_URL"] ? URI.parse(ENV.fetch("DATABASE_URL")).scheme : database_config.fetch("adapter")
    raise ArgumentError, "Local CI supports mysql2 and PostgreSQL databases" unless %w[mysql2 postgres postgresql].include?(adapter)
    @postgres = %w[postgres postgresql].include?(adapter)
    browser = Dir["spec/system/**/*_spec.rb"]
    other = Dir["spec/**/*_spec.rb"] - browser
    raise ArgumentError, "No browser or non-browser specs found" if browser.empty? || other.empty?
    @tasks = LOCAL_CI_CHECKS.map { |name, command| Task.new(name: name, commands: [ command ], env: {}) }
    self.class.shards(browser, browser_jobs).each_with_index { |files, i| @tasks << spec_task("browser-#{i + 1}", files) }
    self.class.shards(other, jobs).each_with_index { |files, i| @tasks << spec_task("specs-#{i + 1}", files) }
    @tasks << database_task("seeds", [ [ "bin/rails", "db:seed" ], [ "bin/rails", "db:seed" ] ])
  end

  def describe
    puts "Local CI: #{@jobs} workers, RSpec seed #{@seed}"
    puts "Logs and reports: #{directory}"
    tasks.each do |task|
      count = task.commands.flatten.count { |arg| arg.end_with?("_spec.rb") }
      puts "  #{task.name}#{count.positive? ? " (#{count} spec files)" : ''}#{task.database ? ' — isolated database' : ''}"
    end
  end

  def run
    describe
    FileUtils.mkdir_p(directory)
    queue = Queue.new
    tasks.each { |task| queue << task }
    threads = Array.new([ @jobs, tasks.length ].min) do
      Thread.new do
        loop do
          task = queue.pop(true)
          break if @interrupted
          execute(task)
        rescue ThreadError
          break
        end
      end
    end
    previous_term = Signal.trap("TERM") { raise Interrupt }
    begin
      threads.each(&:join)
    rescue Interrupt
      pids = []
      @mutex.synchronize do
        @interrupted = true
        pids = @children.keys
        pids.each { |pid| signal_group("TERM", pid) }
      end
      puts "Interrupted; stopping workers and removing their databases…"
      killer = Thread.new do
        sleep 5
        @mutex.synchronize { pids.each { |pid| signal_group("KILL", pid) if @children.key?(pid) } }
      end
      threads.each(&:join)
    ensure
      killer&.kill
      killer&.join
      Signal.trap("TERM", previous_term)
    end
    File.write(File.join(directory, "summary.json"), JSON.pretty_generate(@results))
    passed = !@interrupted && @results.length == tasks.length && @results.values.all?
    puts "#{passed ? 'PASS' : 'FAIL'}: #{@results.count { |_, result| result }}/#{tasks.length} checks passed (#{directory})"
    passed
  end

  private
    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      # The command completed between the snapshot and the signal.
    end

    def spec_task(name, files)
      report = File.join(directory, "#{name}.json")
      task = database_task(name, [ [ "bundle", "exec", "rspec", *files, "--seed", @seed.to_s,
        "--format", "progress", "--format", "json", "--out", report ] ])
      task.report = report
      task
    end

    def database_task(name, commands)
      database = "coplan_ci_#{Digest::SHA256.hexdigest(directory)[0, 12]}_#{name.tr('-', '_')}"
      env = { "RAILS_ENV" => "test", "COPLAN_TEST_DATABASE" => database,
        "SCHEMA" => File.join(directory, "#{name}-schema.rb") }
      if ENV["DATABASE_URL"]
        url = URI.parse(ENV.fetch("DATABASE_URL"))
        url.path = "/#{database}"
        # Active Record query parameters take precedence over the URL path.
        params = URI.decode_www_form(url.query || "").reject { |key, _| key == "database" }
        params << [ "encoding", "unicode" ] if @postgres && params.none? { |key, _| key == "encoding" }
        url.query = params.empty? ? nil : URI.encode_www_form(params)
        env["DATABASE_URL"] = url.to_s
      end
      Task.new(name: name, commands: commands, env: env, database: database)
    end

    def command(task, args, log, cleanup: false)
      pid = @mutex.synchronize do
        return false if @interrupted && !cleanup
        Process.spawn(task.env, *args, out: log, err: log, pgroup: true).tap { |child| @children[child] = true }
      end
      _, status = Process.wait2(pid)
      status.success?
    ensure
      @mutex.synchronize { @children.delete(pid) } if pid
    end

    def execute(task)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      path = File.join(directory, "#{task.name}.log")
      puts "START #{task.name}"
      passed = false
      File.open(path, "w") do |log|
        begin
          if task.database
            FileUtils.cp("db/schema.rb", task.env.fetch("SCHEMA")) unless @postgres
            setup = [ "bin/rails", "db:create", @postgres ? "db:migrate" : "db:schema:load" ]
            return unless command(task, setup, log)
          end
          passed = task.commands.all? { |args| command(task, args, log) }
          if passed && task.report
            summary = JSON.parse(File.read(task.report)).fetch("summary")
            passed = summary.fetch("example_count").positive? && summary.fetch("failure_count").zero?
          end
        rescue StandardError => error
          log.puts "#{error.class}: #{error.message}"
          passed = false
        ensure
          if task.database
            begin
              dropped = command(task, [ "bin/rails", "db:drop" ], log, cleanup: true)
              passed &&= dropped
            rescue StandardError => error
              log.puts "Database cleanup failed: #{error.class}: #{error.message}"
              passed = false
            end
          end
        end
      end
    ensure
      @mutex.synchronize { @results[task.name] = passed }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts "#{passed ? 'PASS' : 'FAIL'} #{task.name} (#{elapsed.round(1)}s) — #{path}"
    end
end
