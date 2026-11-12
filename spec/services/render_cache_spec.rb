require "rails_helper"
require "tmpdir"

RSpec.describe CoPlan::RenderCache do
  # Each instance represents a separate boot of a release, with its own memo.
  let(:release) { Class.new(described_class) }

  around do |example|
    original = ENV.to_h.slice("RAILS_CACHE_ID", "RAILS_APP_VERSION")
    ENV.delete("RAILS_CACHE_ID")
    ENV.delete("RAILS_APP_VERSION")
    Dir.mktmpdir do |directory|
      @lockfile = Pathname.new(directory).join("Gemfile.lock")
      example.run
    end
  ensure
    ENV.delete("RAILS_CACHE_ID")
    ENV.delete("RAILS_APP_VERSION")
    original.each { |name, value| ENV[name] = value }
  end

  before do
    allow(Rails.application.config).to receive(:reloading_enabled?).and_return(false)
    allow(Bundler).to receive(:default_lockfile).and_return(@lockfile)
    allow(Bundler).to receive(:locked_gems) { Bundler::LockfileParser.new(@lockfile.read) }
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  def write_lock(version: "1.1.0", revision: nil, path: nil, parser_version: "2.4.0")
    engine = "    coplan-engine (#{version})\n"
    source = if revision
      "GIT\n  remote: https://github.com/block/coplan.git\n  revision: #{revision}\n  specs:\n#{engine}\n"
    elsif path
      "PATH\n  remote: #{path}\n  specs:\n#{engine}\n"
    else
      ""
    end
    gems = "GEM\n  remote: https://rubygems.org/\n  specs:\n"
    gems += engine unless revision || path
    gems += "    commonmarker (#{parser_version})\n\nDEPENDENCIES\n  coplan-engine#{'!' if revision || path}\n"
    @lockfile.write(source + gems)
  end

  it "reuses rendered output for the same installed gem release without a host variable" do
    write_lock
    expect(release.fetch([ "example", "content-sha" ]) { "first render" }).to eq("first render")
    expect(Class.new(described_class).fetch([ "example", "content-sha" ]) { "second render" }).to eq("first render")
  end

  it "invalidates persistent output when the installed engine gem version changes" do
    write_lock
    release.fetch([ "example", "unchanged-content" ]) { "old HTML" }
    write_lock(version: "1.2.0")
    expect(Class.new(described_class).fetch([ "example", "unchanged-content" ]) { "new HTML" }).to eq("new HTML")
  end

  it "invalidates Git-pinned engine updates even when the gem version stays the same" do
    write_lock(revision: "b40c2c32681e1ad4d7fadbb80392510d90cb08e2")
    release.fetch([ "example", "unchanged-content" ]) { "deployed HTML" }
    write_lock(revision: "f2693895b48fab820c579728715ce90daaf0dd1a")
    expect(Class.new(described_class).fetch([ "example", "unchanged-content" ]) { "candidate HTML" }).to eq("candidate HTML")
  end

  it "does not ask Git for a revision or depend on an installed checkout directory name" do
    write_lock(revision: "f2693895b48fab820c579728715ce90daaf0dd1a")
    expect_any_instance_of(Bundler::Source::Git).not_to receive(:revision)
    expect(release.version).to be_present
  end

  it "invalidates output when a rendering dependency changes" do
    write_lock
    original = release.version
    write_lock(parser_version: "2.5.0")
    expect(Class.new(described_class).version).not_to eq(original)
  end

  it "does not read the lockfile again on later lookups in the same process" do
    write_lock
    original = release.version
    expect(Digest::SHA256).not_to receive(:file)
    expect(release.version).to equal(original)
  end

  it "bypasses rendered caches for editable path installs without a release ID" do
    write_lock(path: "engine")
    expect(release.version).to be_nil
    expect(Rails.cache).not_to receive(:fetch)
    expect(release.fetch([ "example" ]) { "first render" }).to eq("first render")
    expect(release.fetch([ "example" ]) { "updated renderer" }).to eq("updated renderer")
  end

  it "also bypasses caches when another dependency is an editable path source" do
    write_lock
    @lockfile.write("PATH\n  remote: local-renderer\n  specs:\n    custom-renderer (1.0)\n\n" + @lockfile.read)
    expect(release.version).to be_nil
  end

  %w[RAILS_APP_VERSION RAILS_CACHE_ID].each do |name|
    it "uses Rails' #{name} namespace for path-based production releases" do
      write_lock(path: "engine")
      ENV[name] = "release-a"
      release.fetch([ "example" ]) { "release A" }
      expect(release.fetch([ "example" ]) { "cached" }).to eq("release A")
      ENV[name] = "release-b"
      expect(Class.new(described_class).fetch([ "example" ]) { "release B" }).to eq("release B")
    end
  end

  it "does not cache while development reloading is enabled, even with a release ID" do
    write_lock
    ENV["RAILS_APP_VERSION"] = "release-a"
    allow(Rails.application.config).to receive(:reloading_enabled?).and_return(true)
    expect(release.version).to be_nil
    expect(Rails.cache).not_to receive(:fetch)
    expect(release.fetch([ "example" ]) { "fresh HTML" }).to eq("fresh HTML")
  end

  it "falls back to the installed gem version without Bundler or a lockfile" do
    hide_const("Bundler")
    gem = Gem::Specification.new { |spec| spec.name = "coplan-engine"; spec.version = "1.2.0" }
    allow(Gem).to receive(:loaded_specs).and_return("coplan-engine" => gem)
    expect(release.version).to eq("coplan-engine-1.2.0")
  end
end
