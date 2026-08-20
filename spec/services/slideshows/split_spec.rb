require "rails_helper"

RSpec.describe CoPlan::Slideshows::Split do
  def split(content)
    described_class.call(content)
  end

  describe "slide boundaries" do
    it "splits on top-level --- thematic breaks" do
      result = split("# One\n\nfirst\n\n---\n\n# Two\n\nsecond")

      expect(result.slides.map(&:index)).to eq([ 1, 2 ])
      expect(result.slides.first.source).to include("# One")
      expect(result.slides.first.source).not_to include("Two")
      expect(result.slides.second.source).to include("# Two")
    end

    it "returns the whole document as one slide when there are no breaks" do
      result = split("# Only\n\nslide")

      expect(result.slides.size).to eq(1)
      expect(result.slides.first.source).to eq("# Only\n\nslide")
    end

    it "records 1-based start/end lines into the original document, blank edges trimmed" do
      result = split("# One\n\nfirst\n\n---\n\n# Two")

      one, two = result.slides
      expect(one.start_line).to eq(1)
      expect(one.end_line).to eq(3)
      expect(two.start_line).to eq(7)
      expect(two.end_line).to eq(7)
    end

    it "accepts more than three dashes and up to three leading spaces" do
      result = split("a\n\n----------\n\nb\n\n   ---\n\nc")

      expect(result.slides.map(&:source)).to eq(%w[a b c])
    end

    it "drops the empty slide from a leading ---" do
      result = split("---\n\n# Deck starts here")

      expect(result.slides.size).to eq(1)
      expect(result.slides.first.index).to eq(1)
      expect(result.slides.first.source).to include("Deck starts here")
    end

    it "collapses consecutive breaks instead of emitting empty slides" do
      result = split("a\n\n---\n\n---\n\n---\n\nb")

      expect(result.slides.map(&:source)).to eq(%w[a b])
      expect(result.slides.map(&:index)).to eq([ 1, 2 ])
    end

    it "splits CRLF content the same as LF content" do
      result = split("a\r\n\r\n---\r\n\r\nb")

      expect(result.slides.map(&:source)).to eq(%w[a b])
    end

    it "returns no slides for blank content" do
      expect(split("").slides).to be_empty
      expect(split(nil).slides).to be_empty
      expect(split("   \n\n  ").slides).to be_empty
    end
  end

  describe "non-boundaries" do
    it "does not split on --- inside a code fence" do
      content = "before\n\n```\n---\n```\n\nafter"
      result = split(content)

      expect(result.slides.size).to eq(1)
      expect(result.slides.first.source).to eq(content)
    end

    it "does not split on *** or ___ thematic breaks" do
      result = split("a\n\n***\n\nb\n\n___\n\nc")

      expect(result.slides.size).to eq(1)
    end

    it "does not split on spaced dashes (- - -)" do
      result = split("a\n\n- - -\n\nb")

      expect(result.slides.size).to eq(1)
    end

    it "treats --- under text as the setext heading it is, not a break" do
      result = split("Heading text\n---\n\nbody")

      expect(result.slides.size).to eq(1)
      expect(result.slides.first.source).to include("Heading text")
    end

    it "does not split on --- inside a blockquote" do
      result = split("a\n\n> quote\n> ---\n\nb")

      expect(result.slides.size).to eq(1)
    end
  end

  describe "speaker notes" do
    it "extracts a notes comment and assigns it to its slide" do
      result = split("# One\n\n<!-- notes: say hi -->\n\n---\n\n# Two")

      expect(result.slides.first.notes).to eq([ "say hi" ])
      expect(result.slides.second.notes).to eq([])
    end

    it "handles multi-line notes and multiple notes per slide" do
      content = <<~MD
        # Slide

        <!-- notes:
        first line
        second line
        -->

        <!-- notes also this -->
      MD
      result = split(content)

      expect(result.slides.first.notes).to eq([ "first line\nsecond line", "also this" ])
    end

    it "ignores comments that are not notes" do
      result = split("# Slide\n\n<!-- just a comment -->")

      expect(result.slides.first.notes).to eq([])
    end

    it "requires notes to be a whole word, not a prefix" do
      result = split("# Slide\n\n<!-- notesque aside -->\n\n<!-- notes-to-self: fix later -->\n\n<!-- notesXYZ -->")

      expect(result.slides.first.notes).to eq([])
    end

    it "keeps the notes comment inside the slide source" do
      result = split("# Slide\n\n<!-- notes: hidden -->")

      expect(result.slides.first.source).to include("<!-- notes: hidden -->")
    end
  end

  describe "shared definitions" do
    it "gathers footnote definitions from anywhere in the document" do
      content = "First[^a]\n\n---\n\nSecond\n\n[^a]: the definition"
      result = split(content)

      expect(result.shared_definitions).to include("[^a]: the definition")
    end

    it "gathers link-reference definitions" do
      content = "See [the docs][docs]\n\n---\n\nmore\n\n[docs]: https://example.com \"Docs\""
      result = split(content)

      expect(result.shared_definitions).to include("[docs]: https://example.com")
    end

    it "does not treat definition lookalikes inside code fences as definitions" do
      content = "a\n\n```\n[docs]: https://example.com\n```"
      result = split(content)

      expect(result.shared_definitions).to eq("")
    end

    it "does not gather lines CommonMark rejects as definitions" do
      # An unquoted trailing word invalidates the definition, so the whole
      # line stays visible paragraph text — hoisting it would inject that
      # text onto every slide.
      result = split("[docs]: https://example.com extra words\n\n---\n\nslide two")

      expect(result.shared_definitions).to eq("")
    end

    it "gathers a definition whose destination sits on the next line" do
      content = "See [q][docs]\n\n---\n\n[docs]:\n  https://example.com"
      result = split(content)

      expect(result.shared_definitions).to include("https://example.com")
    end

    it "gathers a definition glued to the top of a paragraph" do
      content = "[docs]: https://example.com\nSee [the docs][docs]\n\n---\n\nAlso [the docs][docs]"
      result = split(content)

      expect(result.shared_definitions).to eq("[docs]: https://example.com")
    end

    it "keeps only the document's first definition of a duplicated key" do
      content = "[docs]: https://first.example\n\na\n\n---\n\n[docs]: https://second.example\n\nb"
      result = split(content)

      expect(result.shared_definitions).to include("first.example")
      expect(result.shared_definitions).not_to include("second.example")
    end

    it "ignores unreferenced footnote definitions instead of misclassifying them as link definitions" do
      # The parser prunes an unreferenced footnote definition, leaving its
      # line unclaimed — it must not be gathered (prepending it back onto its
      # own slide would duplicate the definition and blank the slide).
      result = split("Tail visible prose\n\n[^wip]: draft note not referenced yet")

      expect(result.definition_blocks).to eq([])
    end

    it "keeps a definition whose multi-line title contains a bracket-opening line as one block" do
      result = split("[a]: /u \"open\n[b]: /v\"\n\n---\n\nSee [b] and [a].")

      expect(result.definition_blocks.map(&:key)).to eq([ "link:a" ])
    end

    it "gathers glued definitions with no space after the colon" do
      result = split("[a]:/url\nHello\n\n---\n\nSee [a].")

      expect(result.shared_definitions).to eq("[a]:/url")
    end

    it "case-folds keys so fold-equal footnote labels share one key" do
      result = split("S1[^straße]\n\n[^straße]: eszett\n\n---\n\nS2[^STRASSE]\n\n[^STRASSE]: caps")

      expect(result.definition_blocks.map(&:key).uniq.size).to eq(1)
    end

    it "returns positioned definition blocks for per-slide preambles" do
      content = "Ref[^a]\n\n[^a]: note\n\n---\n\n[docs]: https://example.com\n\nb"
      result = split(content)

      expect(result.definition_blocks.map { |b| [ b.kind, b.key, b.start_line ] })
        .to eq([ [ :footnote, "footnote:a", 3 ], [ :link, "link:docs", 7 ] ])
    end

    it "returns an empty string when there is nothing to share" do
      expect(split("# Plain deck\n\n---\n\nslide two").shared_definitions).to eq("")
    end

    it "keeps multi-line footnote definitions intact" do
      content = "Ref[^long]\n\n[^long]: first line\n    continued line"
      result = split(content)

      expect(result.shared_definitions).to include("continued line")
    end
  end
end
