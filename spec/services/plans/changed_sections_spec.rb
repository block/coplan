require "rails_helper"

RSpec.describe CoPlan::Plans::ChangedSections do
  def call(old_content, new_content)
    described_class.call(old_content: old_content, new_content: new_content)
  end

  it "returns nothing when the content is unchanged" do
    md = "# Title\n\nBody\n\n## Details\n\nMore\n"
    expect(call(md, md)).to eq([])
  end

  it "flags a section whose body changed, keyed by heading slug" do
    old_md = "# Title\n\nBody\n\n## Details\n\nMore\n"
    new_md = "# Title\n\nBody\n\n## Details\n\nMore, edited\n"
    expect(call(old_md, new_md)).to eq([ "details" ])
  end

  it "flags newly added sections" do
    old_md = "# Title\n\nBody\n"
    new_md = "# Title\n\nBody\n\n## Rollout\n\nShip it\n"
    expect(call(old_md, new_md)).to eq([ "rollout" ])
  end

  it "ignores removed sections" do
    old_md = "# Title\n\nBody\n\n## Gone\n\nBye\n"
    new_md = "# Title\n\nBody\n"
    expect(call(old_md, new_md)).to eq([])
  end

  it "keys content before any heading as __top__" do
    expect(call("intro\n# A\n", "different intro\n# A\n")).to eq([ described_class::TOP_KEY ])
  end

  it "treats everything as top content when there are no headings" do
    expect(call("just prose", "different prose")).to eq([ described_class::TOP_KEY ])
  end

  it "only splits on h1-h3, folding deeper headings into their parent section" do
    old_md = "## Plan\n\n#### Sub-detail\n\nold\n"
    new_md = "## Plan\n\n#### Sub-detail\n\nnew\n"
    expect(call(old_md, new_md)).to eq([ "plan" ])
  end

  it "disambiguates duplicate headings with -2/-3 suffixes" do
    old_md = "## Notes\n\na\n\n## Notes\n\nb\n\n## Notes\n\nc\n"
    new_md = "## Notes\n\na\n\n## Notes\n\nCHANGED\n\n## Notes\n\nc\n"
    expect(call(old_md, new_md)).to eq([ "notes-2" ])
  end

  it "does not treat # lines inside code fences as headings" do
    old_md = "# Setup\n\n```\n# not a heading\nold code\n```\n"
    new_md = "# Setup\n\n```\n# not a heading\nnew code\n```\n"
    expect(call(old_md, new_md)).to eq([ "setup" ])
  end

  it "slugifies like the client: links, inline markup, and HTML stripped" do
    old_md = "## See [the docs](https://example.com) & `config` *now*\n\nold\n"
    new_md = "## See [the docs](https://example.com) & `config` *now*\n\nnew\n"
    expect(call(old_md, new_md)).to eq([ "see-the-docs-config-now" ])
  end

  it "handles a heading whose slug comes up empty" do
    old_md = "## ???\n\nold\n"
    new_md = "## ???\n\nnew\n"
    expect(call(old_md, new_md)).to eq([ "section" ])
  end

  it "handles nil and blank inputs" do
    expect(call(nil, nil)).to eq([])
    expect(call(nil, "# Hi\n\nbody\n")).to contain_exactly("hi")
  end

  it "treats setext headings as section boundaries, like the renderer" do
    old_md = "Title\n=====\n\nintro\n\nSub\n---\n\nold\n"
    new_md = "Title\n=====\n\nintro\n\nSub\n---\n\nnew\n"
    expect(call(old_md, new_md)).to eq([ "sub" ])
  end

  it "recognizes ATX headings indented up to three spaces" do
    old_md = "   ## Indented\n\nold\n"
    new_md = "   ## Indented\n\nnew\n"
    expect(call(old_md, new_md)).to eq([ "indented" ])
  end

  it "is not fooled by info strings or fence nesting" do
    old_md = "# Setup\n\n````\n```ruby\n# phantom heading\n```\n````\n\nold\n"
    new_md = "# Setup\n\n````\n```ruby\n# phantom heading\n```\n````\n\nnew\n"
    expect(call(old_md, new_md)).to eq([ "setup" ])
  end

  it "ignores CRLF vs LF line-ending differences between versions" do
    old_md = "# Title\r\n\r\nsame body\r\n\r\n## Extra\r\n\r\nalso same\r\n"
    new_md = "# Title\n\nsame body\n\n## Extra\n\nalso same\n"
    expect(call(old_md, new_md)).to eq([])
  end

  it "flags a newly added heading even when it has no body yet" do
    old_md = "# T\n\nbody\n"
    new_md = "# T\n\nbody\n\n## New steps"
    expect(call(old_md, new_md)).to eq([ "new-steps" ])
  end

  it "slugs HTML entities the way the rendered DOM reads them" do
    old_md = "## AT&amp;T merger\n\nold\n"
    new_md = "## AT&amp;T merger\n\nnew\n"
    expect(call(old_md, new_md)).to eq([ "att-merger" ])
  end
end
