require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "bundler"

RSpec.describe "bin/rspec-system-shard" do
  let(:script) { File.expand_path("../../bin/rspec-system-shard", __dir__) }

  def run_shard(*args, env: {})
    # Avoid Rails bundle startup in list mode, and keep Bundler's startup
    # hook from putting the real bundle executable ahead of our fake one.
    Bundler.with_unbundled_env do
      Open3.capture3(env, RbConfig.ruby, script, *args)
    end
  end

  it "includes every system spec exactly once across the CI shards" do
    shards = (1..4).map do |shard|
      output, error, status = run_shard(shard.to_s, "4", "--list")
      expect(status).to be_success, error
      expect(output.lines).not_to be_empty
      output.lines.map(&:chomp)
    end

    expect(shards.flatten.sort).to eq(Dir["spec/system/**/*_spec.rb"].sort)
  end

  it "rejects invalid and empty shards instead of accidentally running the whole suite" do
    [ [], [ "0", "4" ], [ "5", "4" ], [ "1", "0" ], [ "a", "4" ], [ "9999", "9999" ] ].each do |args|
      output, _error, status = run_shard(*args, "--list")
      expect(status).not_to be_success
      expect(output).to be_empty
    end
  end

  it "forwards the selected files and RSpec options and preserves a failed exit status" do
    Dir.mktmpdir do |directory|
      bundle = File.join(directory, "bundle")
      File.write(bundle, "#!#{RbConfig.ruby}\nrequire 'json'\nputs JSON.generate(ARGV)\nexit 7\n")
      File.chmod(0o755, bundle)

      output, _error, status = run_shard(
        "2", "4", "--seed", "123", "--format", "json", "--out", "tmp/report.json",
        env: { "PATH" => "#{directory}:#{ENV.fetch('PATH')}" }
      )

      expect(status.exitstatus).to eq(7)
      selected = Dir["spec/system/**/*_spec.rb"].sort.each_with_index.filter_map { |file, index| file if index % 4 == 1 }
      expect(JSON.parse(output)).to eq([ "exec", "rspec", *selected, "--seed", "123", "--format", "json", "--out", "tmp/report.json" ])
    end
  end
end
