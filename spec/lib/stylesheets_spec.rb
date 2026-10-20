require "rails_helper"
require "tmpdir"

RSpec.describe "CoPlan stylesheets" do
  around do |example|
    Dir.mktmpdir("coplan-stylesheets") do |directory|
      @directory = Pathname.new(directory)
      FileUtils.cp_r(CoPlan::Engine.root.join("app/assets/stylesheets"), @directory.join("source"))
      example.run
    end
  end

  def assets(prefix: "/assets")
    config = Rails.application.config.assets.dup
    config.paths = [ @directory.join("source") ]
    config.prefix = prefix
    config.output_path = @directory.join("compiled")
    config.manifest_path = config.output_path.join(".manifest.json")
    Propshaft::Assembly.new(config)
  end

  def imports(content)
    content.scan(/@import url\("([^"]+)"\);/).flatten
  end

  it "precompiles native imports to separately emitted, fingerprinted CSS files" do
    assembly = assets
    assembly.processor.process
    entry = assembly.load_path.find("coplan/application.css")
    urls = imports(entry.compiled_content)

    expect(urls).not_to be_empty
    expect(urls.length).to eq(imports(entry.content).length)
    urls.each do |url|
      expect(url).to match(%r{\A/assets/coplan/.+-[0-9a-f]{8}\.css\z})
      compiled_file = assembly.config.output_path.join(url.delete_prefix("/assets/"))
      expect(compiled_file).to exist
      expect(imports(compiled_file.read)).to be_empty
    end

    # The manifest remains imports only; Propshaft must not bundle the rules.
    expect(entry.compiled_content.gsub(%r{/\*.*?\*/}m, "").lines.reject { |line| line.strip.empty? })
      .to all(match(/\A@import /))
  end

  it "changes only an edited leaf and its import manifest, preserving sibling cache keys" do
    before = assets.load_path.assets.to_h { |asset| [ asset.logical_path.to_s, asset.digested_path ] }
    @directory.join("source/coplan/comments.css").open("a") do |file|
      file.write("\n.comment { outline-offset: 3px; }\n")
    end
    assembly = assets
    after = assembly.load_path.assets.to_h { |asset| [ asset.logical_path.to_s, asset.digested_path ] }

    expect(after.keys).to match_array(before.keys)
    expect(after.keys.select { |path| after[path] != before[path] })
      .to contain_exactly("coplan/application.css", "coplan/comments.css")
    expect(imports(assembly.load_path.find("coplan/application.css").compiled_content))
      .to include("/assets/#{after.fetch('coplan/comments.css')}")
  end

  it "resolves imported assets under a host's custom asset prefix" do
    assembly = assets(prefix: "/coplan/assets")
    entry = assembly.load_path.find("coplan/application.css")

    expect(imports(entry.compiled_content)).to all(start_with("/coplan/assets/coplan/"))
  end
end
