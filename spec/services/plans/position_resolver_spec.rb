require "rails_helper"

RSpec.describe CoPlan::Plans::PositionResolver do
  subject(:resolve) { described_class.call(content: content, operation: operation) }

  describe "replace_exact" do
    describe "single occurrence" do
      let(:content) { "Hello world, goodbye world." }
      let(:operation) { { op: "replace_exact", old_text: "goodbye world", new_text: "hello planet" } }

      it "resolves to correct character range" do
        result = resolve
        expect(result.op).to eq("replace_exact")
        expect(result.ranges.length).to eq(1)
        range = result.ranges.first
        expect(content[range[0]...range[1]]).to eq("goodbye world")
      end
    end

    describe "occurrence targeting" do
      let(:content) { "foo bar foo baz foo" }
      let(:operation) { { op: "replace_exact", old_text: "foo", new_text: "qux", occurrence: 2 } }

      it "targets the Nth match (1-indexed)" do
        result = resolve
        range = result.ranges.first
        expect(content[range[0]...range[1]]).to eq("foo")
        expect(range[0]).to eq(8)
        expect(range[1]).to eq(11)
      end
    end

    describe "occurrence: 1 with multiple matches" do
      let(:content) { "foo bar foo baz foo" }
      let(:operation) { { op: "replace_exact", old_text: "foo", new_text: "qux", occurrence: 1 } }

      it "targets the first match" do
        result = resolve
        range = result.ranges.first
        expect(range[0]).to eq(0)
        expect(range[1]).to eq(3)
        expect(content[range[0]...range[1]]).to eq("foo")
      end
    end

    describe "replace_all: true" do
      let(:content) { "foo bar foo baz foo" }
      let(:operation) { { op: "replace_exact", old_text: "foo", new_text: "qux", replace_all: true } }

      it "resolves to all matching ranges" do
        result = resolve
        expect(result.ranges.length).to eq(3)
        result.ranges.each do |range|
          expect(content[range[0]...range[1]]).to eq("foo")
        end
        expect(result.ranges.map(&:first)).to eq([0, 8, 16])
      end
    end

    describe "text at document start" do
      let(:content) { "Hello world" }
      let(:operation) { { op: "replace_exact", old_text: "Hello", new_text: "Hi" } }

      it "range starts at 0" do
        result = resolve
        range = result.ranges.first
        expect(range[0]).to eq(0)
        expect(content[range[0]...range[1]]).to eq("Hello")
      end
    end

    describe "text at document end" do
      let(:content) { "Hello world" }
      let(:operation) { { op: "replace_exact", old_text: "world", new_text: "planet" } }

      it "range ends at content.length" do
        result = resolve
        range = result.ranges.first
        expect(range[1]).to eq(content.length)
        expect(content[range[0]...range[1]]).to eq("world")
      end
    end

    describe "adjacent matches" do
      let(:content) { "aaaa" }
      let(:operation) { { op: "replace_exact", old_text: "aa", new_text: "b", replace_all: true } }

      it "returns non-overlapping ranges" do
        result = resolve
        expect(result.ranges.length).to eq(2)
        expect(result.ranges[0]).to eq([0, 2])
        expect(result.ranges[1]).to eq([2, 4])
      end
    end

    describe "text not found" do
      let(:content) { "Hello world" }
      let(:operation) { { op: "replace_exact", old_text: "missing", new_text: "found" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /found 0 occurrences/)
      end
    end

    describe "occurrence exceeds match count" do
      let(:content) { "foo bar foo" }
      let(:operation) { { op: "replace_exact", old_text: "foo", new_text: "baz", occurrence: 5 } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /occurrence 5 requested but only 2 found/)
      end
    end

    describe "occurrence: 0 is rejected" do
      let(:content) { "foo bar foo" }
      let(:operation) { { op: "replace_exact", old_text: "foo", new_text: "baz", occurrence: 0 } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /occurrence must be >= 1/)
      end
    end

    describe "negative occurrence is rejected" do
      let(:content) { "foo bar foo" }
      let(:operation) { { op: "replace_exact", old_text: "foo", new_text: "baz", occurrence: -1 } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /occurrence must be >= 1/)
      end
    end

    describe "multiple matches without occurrence or replace_all (legacy)" do
      let(:content) { "foo bar foo" }
      let(:operation) { { op: "replace_exact", old_text: "foo", new_text: "baz" } }

      it "raises error" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /found 2 occurrences, expected at most 1/)
      end
    end

    describe "legacy count: 1" do
      let(:content) { "Hello world" }
      let(:operation) { { op: "replace_exact", old_text: "world", new_text: "planet", count: 1 } }

      it "behaves like default (occurrence: 1)" do
        result = resolve
        expect(result.ranges.length).to eq(1)
        range = result.ranges.first
        expect(content[range[0]...range[1]]).to eq("world")
      end
    end

    describe "legacy count: 1 with multiple matches" do
      let(:content) { "foo bar foo" }
      let(:operation) { { op: "replace_exact", old_text: "foo", new_text: "baz", count: 1 } }

      it "raises error like default behavior" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /found 2 occurrences, expected at most 1/)
      end
    end

    describe "legacy count > 1" do
      let(:content) { "foo bar foo baz foo" }
      let(:operation) { { op: "replace_exact", old_text: "foo", new_text: "qux", count: 3 } }

      it "behaves like replace_all" do
        result = resolve
        expect(result.ranges.length).to eq(3)
        result.ranges.each do |range|
          expect(content[range[0]...range[1]]).to eq("foo")
        end
      end
    end

    describe "empty document" do
      let(:content) { "" }
      let(:operation) { { op: "replace_exact", old_text: "hello", new_text: "world" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /found 0 occurrences/)
      end
    end

    describe "requires old_text" do
      let(:content) { "Hello" }
      let(:operation) { { op: "replace_exact", new_text: "Bye" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /requires 'old_text'/)
      end
    end

    describe "requires new_text" do
      let(:content) { "Hello" }
      let(:operation) { { op: "replace_exact", old_text: "Hello" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /requires 'new_text'/)
      end
    end

    describe "works with string keys" do
      let(:content) { "Hello world" }
      let(:operation) { { "op" => "replace_exact", "old_text" => "world", "new_text" => "planet" } }

      it "resolves correctly" do
        result = resolve
        expect(result.ranges.length).to eq(1)
        expect(content[result.ranges.first[0]...result.ranges.first[1]]).to eq("world")
      end
    end
  end

  describe "insert_under_heading" do
    describe "basic heading" do
      let(:content) { "# Title\n\nIntro\n\n## Goals\n\nExisting goals." }
      let(:operation) { { op: "insert_under_heading", heading: "## Goals", content: "- New goal" } }

      it "resolves to zero-width range at end of heading line" do
        result = resolve
        expect(result.op).to eq("insert_under_heading")
        expect(result.ranges.length).to eq(1)
        range = result.ranges.first
        expect(range[0]).to eq(range[1]) # zero-width
        expect(content[range[0]...range[1]]).to eq("") # zero-width insert
        # Verify the position is at the end of "## Goals"
        heading_end = content.index("## Goals") + "## Goals".length
        expect(range[0]).to eq(heading_end)
      end
    end

    describe "different markdown levels" do
      let(:content) { "# H1\n\n## H2\n\n### H3\n\nContent" }

      it "resolves ### heading" do
        result = described_class.call(content: content, operation: { op: "insert_under_heading", heading: "### H3", content: "new" })
        range = result.ranges.first
        heading_end = content.index("### H3") + "### H3".length
        expect(range[0]).to eq(heading_end)
      end

      it "resolves # heading" do
        result = described_class.call(content: content, operation: { op: "insert_under_heading", heading: "# H1", content: "new" })
        range = result.ranges.first
        expect(range[0]).to eq("# H1".length)
      end
    end

    describe "heading at document start" do
      let(:content) { "## Start\n\nSome content." }
      let(:operation) { { op: "insert_under_heading", heading: "## Start", content: "inserted" } }

      it "resolves correctly" do
        result = resolve
        range = result.ranges.first
        expect(range[0]).to eq("## Start".length)
      end
    end

    describe "heading not found" do
      let(:content) { "# Title\n\nContent" }
      let(:operation) { { op: "insert_under_heading", heading: "## Missing", content: "stuff" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /no heading matching/)
      end
    end

    describe "ambiguous heading" do
      let(:content) { "## Goals\n\nFirst\n\n## Goals\n\nSecond" }
      let(:operation) { { op: "insert_under_heading", heading: "## Goals", content: "stuff" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /found 2 headings/)
      end
    end

    describe "requires heading" do
      let(:content) { "# Title" }
      let(:operation) { { op: "insert_under_heading", content: "stuff" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /requires 'heading'/)
      end
    end

    describe "requires content" do
      let(:content) { "# Title" }
      let(:operation) { { op: "insert_under_heading", heading: "# Title" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /requires 'content'/)
      end
    end
  end

  describe "delete_paragraph_containing" do
    describe "middle paragraph" do
      let(:content) { "First paragraph.\n\nThis is deprecated.\n\nThird paragraph." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "deprecated" } }

      it "resolves to correct range and content reconstruction is correct" do
        result = resolve
        expect(result.op).to eq("delete_paragraph_containing")
        range = result.ranges.first
        reconstructed = content[0...range[0]] + content[range[1]..]
        expect(reconstructed).to eq("First paragraph.\n\nThird paragraph.")
      end
    end

    describe "first paragraph" do
      let(:content) { "Remove me.\n\nKeep this.\n\nAnd this too." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "Remove me" } }

      it "resolves to correct range" do
        result = resolve
        range = result.ranges.first
        reconstructed = content[0...range[0]] + content[range[1]..]
        expect(reconstructed).to eq("Keep this.\n\nAnd this too.")
      end
    end

    describe "last paragraph" do
      let(:content) { "First thing.\n\nSecond thing.\n\nDelete this one." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "Delete this" } }

      it "resolves to correct range" do
        result = resolve
        range = result.ranges.first
        reconstructed = content[0...range[0]] + content[range[1]..]
        expect(reconstructed).to eq("First thing.\n\nSecond thing.")
      end
    end

    describe "only paragraph" do
      let(:content) { "The only paragraph here." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "only paragraph" } }

      it "resolves to entire document" do
        result = resolve
        range = result.ranges.first
        expect(range).to eq([0, content.length])
        reconstructed = content[0...range[0]] + content[range[1]..]
        expect(reconstructed).to eq("")
      end
    end

    describe "multiple newlines between paragraphs" do
      let(:content) { "First.\n\n\n\nMiddle to delete.\n\n\n\nLast." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "Middle to delete" } }

      it "produces correct content with proper spacing" do
        result = resolve
        range = result.ranges.first
        reconstructed = content[0...range[0]] + content[range[1]..]
        expect(reconstructed).to eq("First.\n\n\n\nLast.")
      end
    end

    describe "first paragraph with multiple newlines" do
      let(:content) { "Delete first.\n\n\nSecond stays." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "Delete first" } }

      it "produces correct content" do
        result = resolve
        range = result.ranges.first
        reconstructed = content[0...range[0]] + content[range[1]..]
        expect(reconstructed).to eq("Second stays.")
      end
    end

    describe "last paragraph with multiple newlines before it" do
      let(:content) { "Stays.\n\n\nDelete last." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "Delete last" } }

      it "produces correct content" do
        result = resolve
        range = result.ranges.first
        reconstructed = content[0...range[0]] + content[range[1]..]
        expect(reconstructed).to eq("Stays.")
      end
    end

    describe "needle not found" do
      let(:content) { "Some content here." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "missing" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /no paragraph containing/)
      end
    end

    describe "ambiguous needle" do
      let(:content) { "First deprecated thing.\n\nSecond deprecated thing." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "deprecated" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /found 2 paragraphs/)
      end
    end

    describe "requires needle" do
      let(:content) { "Some content." }
      let(:operation) { { op: "delete_paragraph_containing" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /requires 'needle'/)
      end
    end

    describe "paragraph with trailing newline at end of document" do
      let(:content) { "Keep this.\n\nRemove this.\n" }
      let(:operation) { { op: "delete_paragraph_containing", needle: "Remove this" } }

      it "produces correct content" do
        result = resolve
        range = result.ranges.first
        reconstructed = content[0...range[0]] + content[range[1]..]
        expect(reconstructed).to eq("Keep this.")
      end
    end

    describe "multi-line paragraph" do
      let(:content) { "First.\n\nLine one of para.\nLine two of para.\n\nThird." }
      let(:operation) { { op: "delete_paragraph_containing", needle: "Line one" } }

      it "deletes the entire multi-line paragraph" do
        result = resolve
        range = result.ranges.first
        reconstructed = content[0...range[0]] + content[range[1]..]
        expect(reconstructed).to eq("First.\n\nThird.")
      end
    end
  end

  describe "replace_section" do
    describe "basic section replacement" do
      let(:content) { "# Title\n\nIntro.\n\n## Goals\n\nGoal 1.\n\n## Timeline\n\nQ1." }
      let(:operation) { { op: "replace_section", heading: "## Goals", new_content: "## Goals\n\nNew." } }

      it "resolves to the section range from heading to next equal-level heading" do
        result = resolve
        expect(result.op).to eq("replace_section")
        range = result.ranges.first
        section_text = content[range[0]...range[1]]
        expect(section_text).to include("## Goals")
        expect(section_text).to include("Goal 1.")
        expect(section_text).not_to include("## Timeline")
      end
    end

    describe "last section extends to EOF" do
      let(:content) { "# Title\n\n## Goals\n\nGoal 1.\n\n## Timeline\n\nQ1 2025." }
      let(:operation) { { op: "replace_section", heading: "## Timeline", new_content: "New." } }

      it "resolves range to end of document" do
        result = resolve
        range = result.ranges.first
        section_text = content[range[0]...range[1]]
        expect(section_text).to include("## Timeline")
        expect(section_text).to include("Q1 2025.")
      end
    end

    describe "include_heading: false" do
      let(:content) { "# Title\n\n## Goals\n\nGoal 1.\n\n## Timeline\n\nQ1." }
      let(:operation) { { op: "replace_section", heading: "## Goals", new_content: "New body.", include_heading: false } }

      it "resolves range to body only (excludes heading line)" do
        result = resolve
        range = result.ranges.first
        section_text = content[range[0]...range[1]]
        expect(section_text).not_to include("## Goals")
        expect(section_text).to include("Goal 1.")
      end
    end

    describe "sub-headings are included in section" do
      let(:content) { "## Section\n\nBody.\n\n### Sub\n\nSub body.\n\n## Next\n\nOther." }
      let(:operation) { { op: "replace_section", heading: "## Section", new_content: "New." } }

      it "includes sub-headings in the section range" do
        result = resolve
        range = result.ranges.first
        section_text = content[range[0]...range[1]]
        expect(section_text).to include("### Sub")
        expect(section_text).to include("Sub body.")
        expect(section_text).not_to include("## Next")
      end
    end

    describe "code fence protection" do
      let(:content) { "## Real\n\nContent.\n\n```\n## Fake\n```\n\n## After\n\nMore." }
      let(:operation) { { op: "replace_section", heading: "## Real", new_content: "New." } }

      it "does not treat headings inside code fences as section boundaries" do
        result = resolve
        range = result.ranges.first
        section_text = content[range[0]...range[1]]
        expect(section_text).to include("## Fake")
        expect(section_text).not_to include("## After")
      end
    end

    describe "heading not found" do
      let(:content) { "# Title\n\nContent." }
      let(:operation) { { op: "replace_section", heading: "## Missing", new_content: "x" } }

      it "raises OperationError with heading_not_found" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /heading_not_found/)
      end
    end

    describe "ambiguous heading" do
      let(:content) { "## Goals\n\nFirst.\n\n## Goals\n\nSecond." }
      let(:operation) { { op: "replace_section", heading: "## Goals", new_content: "x" } }

      it "raises OperationError with ambiguous_heading and line numbers" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /ambiguous_heading/)
      end
    end

    describe "requires heading" do
      let(:content) { "# Title" }
      let(:operation) { { op: "replace_section", new_content: "x" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /requires 'heading'/)
      end
    end

    describe "requires new_content" do
      let(:content) { "# Title" }
      let(:operation) { { op: "replace_section", heading: "# Title" } }

      it "raises OperationError" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /requires 'new_content'/)
      end
    end

    describe "heading inside code fence is not matched" do
      let(:content) { "```\n## InFence\n```\n\nParagraph." }
      let(:operation) { { op: "replace_section", heading: "## InFence", new_content: "x" } }

      it "raises heading_not_found" do
        expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /heading_not_found/)
      end
    end
  end

  describe "unknown operation" do
    let(:content) { "Hello" }
    let(:operation) { { op: "bogus_op" } }

    it "raises OperationError" do
      expect { resolve }.to raise_error(CoPlan::Plans::OperationError, /Unknown operation/)
    end
  end
end
