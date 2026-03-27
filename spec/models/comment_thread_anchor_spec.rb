require "rails_helper"

RSpec.describe CoPlan::CommentThread, "anchor tracking" do
  let(:user) { create(:coplan_user) }
  let(:content) { "# My Plan\n\nFirst section.\n\n## Goals\n\nWe should use unit tests.\n\n## Timeline\n\nQ1 2026." }
  let(:plan) do
    plan = CoPlan::Plan.create!(title: "Test", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: plan, revision: 1,
      content_markdown: content, actor_type: "human", actor_id: user.id
    )
    plan.update!(current_plan_version: version, current_revision: 1)
    plan
  end

  describe "resolve_anchor_position on create" do
    it "resolves anchor_text to character positions" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )
      expect(thread.anchor_start).to be_present
      expect(thread.anchor_end).to be_present
      expect(thread.anchor_revision).to eq(1)
      expect(content[thread.anchor_start...thread.anchor_end]).to eq("unit tests")
    end

    context "when anchor text spans markdown formatting" do
      # Helper: create a plan with the given markdown, then create a thread
      # anchored to `dom_text` (what the browser selection returns). Asserts
      # that the resolved raw range matches `expected_raw`.
      def assert_anchor_resolves(markdown, dom_text, expected_raw, occurrence: nil)
        p = CoPlan::Plan.create!(title: "Test", created_by_user: user)
        v = CoPlan::PlanVersion.create!(
          plan: p, revision: 1,
          content_markdown: markdown, actor_type: "human", actor_id: user.id
        )
        p.update!(current_plan_version: v, current_revision: 1)

        attrs = {
          plan_version: p.current_plan_version,
          created_by_user: user,
          anchor_text: dom_text
        }
        attrs[:anchor_occurrence] = occurrence if occurrence

        thread = p.comment_threads.create!(**attrs)
        expect(thread.anchor_start).to be_present, "anchor_start should be set for #{dom_text.inspect}"
        expect(thread.anchor_end).to be_present
        matched = markdown[thread.anchor_start...thread.anchor_end]
        expect(matched).to eq(expected_raw),
          "Expected raw range to be #{expected_raw.inspect}, got #{matched.inspect}"
        thread
      end

      it "inline code (backticks)" do
        assert_anchor_resolves(
          "Hello `me` you should read this.",
          "Hello me you",
          "Hello `me` you"
        )
      end

      it "double backtick code spans" do
        assert_anchor_resolves(
          "Use ``code here`` please.",
          "Use code here please",
          "Use ``code here`` please"
        )
      end

      it "bold (**)" do
        assert_anchor_resolves(
          "Hello **world** today.",
          "Hello world today",
          "Hello **world** today"
        )
      end

      it "italic (*)" do
        assert_anchor_resolves(
          "Hello *world* today.",
          "Hello world today",
          "Hello *world* today"
        )
      end

      it "bold with underscores (__)" do
        assert_anchor_resolves(
          "Hello __world__ today.",
          "Hello world today",
          "Hello __world__ today"
        )
      end

      it "italic with underscores (_)" do
        assert_anchor_resolves(
          "Hello _world_ today.",
          "Hello world today",
          "Hello _world_ today"
        )
      end

      it "strikethrough (~~)" do
        assert_anchor_resolves(
          "Hello ~~old~~ new.",
          "Hello old new",
          "Hello ~~old~~ new"
        )
      end

      it "nested bold and italic" do
        assert_anchor_resolves(
          "Hello **bold _and_ italic** end.",
          "Hello bold and italic end",
          "Hello **bold _and_ italic** end"
        )
      end

      it "link text (strips [](url) syntax)" do
        assert_anchor_resolves(
          "See [the docs](http://example.com) for details.",
          "See the docs for details",
          "See [the docs](http://example.com) for details"
        )
      end

      it "table cell text" do
        md = "# Plan\n\n| Name | Status |\n|------|--------|\n| Alpha | Done |"
        assert_anchor_resolves(md, "Alpha", "Alpha")
      end

      it "text spanning multiple table cells (spaces)" do
        md = "| Phase | Engineers | Duration |\n|-------|-----------|----------|\n| Phase 1 | 15 | 3 months |"
        # Raw range spans from first cell text through last, including pipe delimiters.
        assert_anchor_resolves(md, "Phase 1 15 3 months", "Phase 1 | 15 | 3 months")
      end

      it "text spanning multiple table cells (tabs from browser selection)" do
        md = "| Phase | Engineers | Duration |\n|-------|-----------|----------|\n| Phase 1 | 15 | 3 months |"
        # Browser selection.toString() uses tabs between cells;
        # the server normalizes tabs to spaces before matching.
        assert_anchor_resolves(md, "Phase 1\t15\t3 months", "Phase 1 | 15 | 3 months")
      end

      it "table cell text spanning formatted content" do
        md = "| Name | Status |\n|------|--------|\n| Alpha | **Done** |"
        assert_anchor_resolves(md, "Done", "Done")
      end

      it "table cell text with inline code" do
        md = "| Func | Desc |\n|------|------|\n| `run` | Runs it |"
        assert_anchor_resolves(md, "run", "run")
      end

      it "heading text (strips # markers)" do
        assert_anchor_resolves(
          "# My Heading\n\nContent here.",
          "My Heading",
          "My Heading"
        )
      end

      it "blockquote text" do
        assert_anchor_resolves(
          "> This is quoted text.\n\nNormal text.",
          "This is quoted text.",
          "This is quoted text."
        )
      end

      it "list item text" do
        assert_anchor_resolves(
          "- First item\n- Second item",
          "Second item",
          "Second item"
        )
      end

      it "multiple occurrences with formatting" do
        md = "Say `hello` friend. Say `hello` again."
        # First occurrence
        t1 = assert_anchor_resolves(md, "hello", "hello", occurrence: 1)
        # Second occurrence
        t2 = assert_anchor_resolves(md, "hello", "hello", occurrence: 2)
        expect(t2.anchor_start).to be > t1.anchor_start
      end

      it "text with emoji before formatted content" do
        assert_anchor_resolves(
          "Hello 🌍 **world** end.",
          "Hello 🌍 world end",
          "Hello 🌍 **world** end"
        )
      end

      it "inline code containing emoji" do
        assert_anchor_resolves(
          "Run `cmd 🚀` now.",
          "Run cmd 🚀 now",
          "Run `cmd 🚀` now"
        )
      end

      it "fenced code block text" do
        md = "# Plan\n\n```ruby\ndef hello\n  puts 'hi'\nend\n```\n\nDone."
        assert_anchor_resolves(md, "def hello", "def hello")
      end

      it "plain text still works via exact match (fast path)" do
        assert_anchor_resolves(
          "Plain text without any formatting.",
          "without any",
          "without any"
        )
      end
    end

    it "handles missing anchor_text gracefully" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user
      )
      expect(thread.anchor_start).to be_nil
    end
  end

  describe "mark_out_of_date_for_new_version! with positions" do
    it "does NOT mark outdated when edit is in unrelated section" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )

      # Edit the timeline section (after the anchor)
      new_content = content.sub("Q1 2026", "Q2 2026")
      anchor_pos = content.index("Q1 2026")
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human", actor_id: user.id,
        operations_json: [{ "op" => "replace_exact", "resolved_range" => [anchor_pos, anchor_pos + 7], "new_range" => [anchor_pos, anchor_pos + 7], "delta" => 0 }]
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      CoPlan::CommentThread.mark_out_of_date_for_new_version!(version2)
      thread.reload
      expect(thread.out_of_date).to be false
    end

    it "marks outdated when edit overlaps with anchor" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )

      # Edit that directly modifies the anchored text
      unit_test_pos = content.index("unit tests")
      new_content = content.sub("unit tests", "integration tests")
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human", actor_id: user.id,
        operations_json: [{ "op" => "replace_exact", "resolved_range" => [unit_test_pos, unit_test_pos + 10], "new_range" => [unit_test_pos, unit_test_pos + 17], "delta" => 7 }]
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      CoPlan::CommentThread.mark_out_of_date_for_new_version!(version2)
      thread.reload
      expect(thread.out_of_date).to be true
    end

    it "shifts anchor positions when edit is before anchor" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )
      original_start = thread.anchor_start

      # Insert text before the anchor
      new_content = content.sub("First section.", "First longer section with more detail.")
      first_pos = content.index("First section.")
      first_len = "First section.".length
      new_len = "First longer section with more detail.".length
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human", actor_id: user.id,
        operations_json: [{ "op" => "replace_exact", "resolved_range" => [first_pos, first_pos + first_len], "new_range" => [first_pos, first_pos + new_len], "delta" => new_len - first_len }]
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      CoPlan::CommentThread.mark_out_of_date_for_new_version!(version2)
      thread.reload
      expect(thread.out_of_date).to be false
      expect(thread.anchor_start).to eq(original_start + (new_len - first_len))
    end

    it "marks out-of-date when thread lacks positional data" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )
      thread.update_columns(anchor_start: nil, anchor_end: nil, anchor_revision: nil)

      new_content = content.sub("Q1 2026", "Q2 2026")
      anchor_pos = content.index("Q1 2026")
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: new_content, actor_type: "human", actor_id: user.id,
        operations_json: [{ "op" => "replace_exact", "resolved_range" => [anchor_pos, anchor_pos + 7], "new_range" => [anchor_pos, anchor_pos + 7], "delta" => 0 }]
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      CoPlan::CommentThread.mark_out_of_date_for_new_version!(version2)
      thread.reload
      expect(thread.out_of_date).to be true
    end
  end

  describe "#anchor_valid?" do
    it "returns true for non-outdated thread" do
      thread = create(:comment_thread, plan: plan, anchor_text: "some text")
      expect(thread.anchor_valid?).to be true
    end

    it "returns false for outdated thread" do
      thread = create(:comment_thread, plan: plan, anchor_text: "some text", out_of_date: true)
      expect(thread.anchor_valid?).to be false
    end

    it "returns true for non-anchored thread" do
      thread = create(:comment_thread, plan: plan)
      expect(thread.anchor_valid?).to be true
    end
  end

  describe "#anchor_occurrence_index with inline formatting" do
    it "returns the correct 0-based index for text spanning inline code" do
      md = "# Plan\n\nSay `hello` to the world. Then say `hello` again."
      p = CoPlan::Plan.create!(title: "Occ Plan", created_by_user: user)
      v = CoPlan::PlanVersion.create!(
        plan: p, revision: 1,
        content_markdown: md, actor_type: "human", actor_id: user.id
      )
      p.update!(current_plan_version: v, current_revision: 1)

      # Create a thread anchored to the second "hello" (occurrence 2)
      thread = p.comment_threads.create!(
        plan_version: p.current_plan_version,
        created_by_user: user,
        anchor_text: "hello",
        anchor_occurrence: 2
      )

      expect(thread.anchor_start).to be_present
      # The frontend sees stripped text; occurrence_index should be 1 (0-based)
      expect(thread.anchor_occurrence_index).to eq(1)
    end

    it "returns 0 for the first occurrence" do
      md = "# Plan\n\nHello **world** today."
      p = CoPlan::Plan.create!(title: "First Occ", created_by_user: user)
      v = CoPlan::PlanVersion.create!(
        plan: p, revision: 1,
        content_markdown: md, actor_type: "human", actor_id: user.id
      )
      p.update!(current_plan_version: v, current_revision: 1)

      thread = p.comment_threads.create!(
        plan_version: p.current_plan_version,
        created_by_user: user,
        anchor_text: "Hello world today"
      )

      expect(thread.anchor_occurrence_index).to eq(0)
    end
  end

  describe ".strip_markdown (delegates to Plans::MarkdownTextExtractor)" do
    it "strips inline code backticks but keeps content" do
      stripped, pos_map = CoPlan::CommentThread.strip_markdown("Hello `code` end")
      expect(stripped).to include("Hello code end")
      # Verify position map points to the actual content chars, not backticks
      code_idx = stripped.index("code")
      expect("Hello `code` end"[pos_map[code_idx]]).to eq("c")
    end

    it "strips bold markers" do
      stripped, _ = CoPlan::CommentThread.strip_markdown("Hello **bold** end")
      expect(stripped).to include("Hello bold end")
    end

    it "strips italic markers" do
      stripped, _ = CoPlan::CommentThread.strip_markdown("Hello *italic* end")
      expect(stripped).to include("Hello italic end")
    end

    it "strips strikethrough markers" do
      stripped, _ = CoPlan::CommentThread.strip_markdown("Hello ~~old~~ end")
      expect(stripped).to include("Hello old end")
    end

    it "strips link syntax, keeping link text" do
      stripped, _ = CoPlan::CommentThread.strip_markdown("See [docs](http://example.com) here")
      expect(stripped).to include("See docs here")
      expect(stripped).not_to include("http://")
    end

    it "extracts table cell text without pipes or separators" do
      md = "| A | B |\n|---|---|\n| 1 | 2 |"
      stripped, _ = CoPlan::CommentThread.strip_markdown(md)
      expect(stripped).to include("A")
      expect(stripped).to include("B")
      expect(stripped).to include("1")
      expect(stripped).to include("2")
      expect(stripped).not_to include("|")
      expect(stripped).not_to include("---")
    end

    it "extracts heading text without # markers" do
      stripped, _ = CoPlan::CommentThread.strip_markdown("## My Heading")
      expect(stripped).to include("My Heading")
      expect(stripped).not_to include("#")
    end

    it "extracts blockquote text without > markers" do
      stripped, _ = CoPlan::CommentThread.strip_markdown("> Quoted text")
      expect(stripped).to include("Quoted text")
      expect(stripped).not_to include(">")
    end

    it "extracts list item text without bullet markers" do
      stripped, _ = CoPlan::CommentThread.strip_markdown("- Item one\n- Item two")
      expect(stripped).to include("Item one")
      expect(stripped).to include("Item two")
      expect(stripped).not_to include("-")
    end

    it "handles nested formatting" do
      stripped, _ = CoPlan::CommentThread.strip_markdown("**bold _and_ italic**")
      expect(stripped).to include("bold and italic")
    end

    it "preserves position map integrity across complex markdown" do
      md = "# Title\n\nHello `world` and **bold** end."
      stripped, pos_map = CoPlan::CommentThread.strip_markdown(md)

      # Every non-sentinel character in stripped should map back to a valid raw position.
      # Sentinel values (-1) are synthetic separators between block elements.
      stripped.each_char.with_index do |char, i|
        raw_pos = pos_map[i]
        next if raw_pos == -1
        expect(raw_pos).to be >= 0
        expect(raw_pos).to be < md.length
        expect(md[raw_pos]).to eq(char), "stripped[#{i}]=#{char.inspect} but md[#{raw_pos}]=#{md[raw_pos].inspect}"
      end
    end

    it "handles multibyte characters correctly in position mapping" do
      md = "Hello 🌍 `world` end"
      stripped, pos_map = CoPlan::CommentThread.strip_markdown(md)

      stripped.each_char.with_index do |char, i|
        raw_pos = pos_map[i]
        next if raw_pos == -1
        expect(raw_pos).to be >= 0
        expect(raw_pos).to be < md.length
        expect(md[raw_pos]).to eq(char), "stripped[#{i}]=#{char.inspect} but md[#{raw_pos}]=#{md[raw_pos].inspect}"
      end
    end

    it "inserts spaces between table cells" do
      md = "| A | B |\n|---|---|\n| 1 | 2 |"
      stripped, _ = CoPlan::CommentThread.strip_markdown(md)
      # Cells should be space-separated, rows newline-separated
      expect(stripped).to include("A B")
      expect(stripped).to include("1 2")
    end

    it "preserves softbreaks as newlines" do
      stripped, _ = CoPlan::CommentThread.strip_markdown("Line one\nline two")
      expect(stripped).to include("Line one\nline two")
    end
  end

  describe "#anchor_context_with_highlight" do
    it "returns context around the anchor with bold markers" do
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        created_by_user: user, anchor_text: "unit tests"
      )

      context = thread.anchor_context_with_highlight(chars: 20)
      expect(context).to include("**unit tests**")
    end

    it "returns nil for non-anchored threads" do
      thread = create(:comment_thread, plan: plan)
      expect(thread.anchor_context_with_highlight).to be_nil
    end
  end
end
