# Standalone Rakefile: the coordinator never boots Rails or opens a database.
require "rake"
require "fileutils"
require "json"
require "shellwords"

jobs = Integer(ENV.fetch("COPLAN_CI_JOBS"))
browsers = Integer(ENV.fetch("COPLAN_CI_BROWSER_JOBS"))
seed = ENV.fetch("COPLAN_CI_SEED")
directory = ENV.fetch("COPLAN_CI_DIRECTORY")
results = {}
checks = {
  "rubocop" => [ "bin/rubocop", "--no-parallel" ],
  "gem-audit" => [ "bin/bundler-audit" ],
  "importmap-audit" => [ "bin/importmap", "audit" ],
  "brakeman" => [ "bin/brakeman", "--quiet", "--no-pager", "--exit-on-warn", "--exit-on-error" ]
}

run = lambda do |name, env, *command|
  path = File.join(directory, "#{name}.log")
  puts "START #{name} — #{path}"
  result = system(env, *command, out: path, err: [ :child, :out ])
  puts "#{result ? 'PASS' : 'FAIL'} #{name} — #{path}"
  result
end

parallel = lambda do |env, count, *args|
  [ env, "bundle", "exec", "parallel_test", "-n", count.to_s, "--first-is-1", *args ]
end

pool = lambda do |name, count, files|
  raise "No #{name} specs found" if files.empty?
  count = [ count, files.length ].min
  env = { "COPLAN_CI_GROUP" => name }
  runtime = File.expand_path("tmp/parallel_runtime_#{name}.log")
  options = Shellwords.join([ "--require", "./lib/ci_database", "--seed", seed, "--format", "progress",
    "--format", "ParallelTests::RSpec::RuntimeLogger", "--out", runtime,
    "--format", "json", "--out", File.join(directory, "#{name}-$TEST_ENV_NUMBER.json") ])
  begin
    passed = run.call("#{name}-prepare", *parallel.call(env, count, "--exec", "bin/ci-db prepare"))
    if passed
      passed = run.call(name, env, "bundle", "exec", "parallel_rspec", "-n", count.to_s, "--first-is-1",
        "--runtime-log", runtime, "--test-options", options, *files)
      reports = Dir[File.join(directory, "#{name}-*.json")]
      passed &&= reports.length == count && reports.all? do |path|
        summary = JSON.parse(File.read(path)).fetch("summary")
        summary.fetch("example_count").positive? && summary.fetch("failure_count").zero?
      end
    end
  ensure
    cleaned = run.call("#{name}-drop", *parallel.call(env, count, "--exec", "bin/ci-db drop"))
    results[name] = passed && cleaned
  end
end

checks.each do |name, command|
  task name do
    results[name] = run.call(name, {}, *command)
  end
end
multitask checks: checks.keys

task :preview do
  puts "Local CI: parallel_tests, #{jobs} non-browser workers, #{browsers} browser workers, seed #{seed}"
  puts "Rake checks: #{checks.keys.join(', ')}"
  puts "RSpec pools: non-browser, then browser; seeds twice on a separate database"
  puts "Logs and reports: #{directory}"
end

task :ci do
  $stdout.sync = true
  FileUtils.mkdir_p(directory)
  Rake::Task[:preview].invoke
  Rake::Task[:checks].invoke
  browser_files = Dir["spec/system/**/*_spec.rb"]
  pool.call("specs", jobs, Dir["spec/**/*_spec.rb"] - browser_files)
  pool.call("browser", browsers, browser_files)
  env = { "COPLAN_CI_GROUP" => "seeds", "TEST_ENV_NUMBER" => "1" }
  begin
    results["seeds"] = run.call("seeds", env, "bin/ci-db", "prepare") &&
      run.call("seeds-first", env, "bin/ci-db", "seed") && run.call("seeds-second", env, "bin/ci-db", "seed")
  ensure
    cleaned = run.call("seeds-drop", env, "bin/ci-db", "drop")
    results["seeds"] &&= cleaned
  end
  File.write(File.join(directory, "summary.json"), JSON.pretty_generate(results))
  abort "Local CI failed; see #{directory}" unless results.values.all?
end
