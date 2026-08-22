require "rails_helper"

RSpec.describe CoPlan::Plans::ChangedSections do
  def result(old_content, new_content)
    described_class.call(old_content: old_content, new_content: new_content)
  end

  def call(old_content, new_content)
    result(old_content, new_content).keys
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

  # Highlighting only helps when it points somewhere. Once most of the
  # document is new — the plan you glanced at mid-draft, or a rewrite —
  # every band lights up and says nothing, so this reports a rewrite and
  # leaves the page alone.
  describe "rewrites" do
    def doc(*bodies)
      bodies.each_with_index.map { |body, i| "## Section #{i + 1}\n\n#{body}\n" }.join("\n")
    end

    it "reports a rewrite instead of keys when most of a long plan changed" do
      old_md = doc("one", "two", "three", "four", "five")
      new_md = doc("wholly new", "also new", "new again", "and this", "five")

      expect(result(old_md, new_md)).to have_attributes(rewritten?: true, keys: [])
    end

    it "still highlights when one long section of many changed" do
      body = "prose " * 200
      old_md = doc(body, "two", "three", "four", "five")
      new_md = doc("#{body} plus an edit", "two", "three", "four", "five")

      expect(result(old_md, new_md)).to have_attributes(rewritten?: false, keys: [ "section-1" ])
    end

    # Section count alone would call this a rewrite; by volume it's a few
    # words against a wall of unchanged text.
    it "still highlights when a swarm of one-line sections changed" do
      long = "prose " * 200
      old_md = doc(long, "a", "b", "c", "d")
      new_md = doc(long, "A", "B", "C", "D")

      expect(result(old_md, new_md)).to have_attributes(
        rewritten?: false,
        keys: [ "section-2", "section-3", "section-4", "section-5" ]
      )
    end

    it "highlights a short plan in full rather than talking about it" do
      old_md = doc("one", "two")
      new_md = doc("new one", "new two")

      expect(result(old_md, new_md)).to have_attributes(rewritten?: false, keys: [ "section-1", "section-2" ])
    end

    it "reports neither keys nor a rewrite when nothing changed" do
      md = doc("one", "two", "three", "four", "five")

      expect(result(md, md)).to have_attributes(rewritten?: false, keys: [])
    end

    # Every section is new against an empty baseline, which is the "you
    # opened it while the agent was still drafting" case.
    it "reports a rewrite when the plan grew from nothing into a long document" do
      expect(result(nil, doc("one", "two", "three", "four"))).to have_attributes(rewritten?: true, keys: [])
    end
  end
end
