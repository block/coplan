require "rails_helper"

RSpec.describe CoPlan::MarkdownHelper, type: :helper do
  before do
    helper.extend(CoPlan::MarkdownHelper)
  end

  describe "#render_markdown with task lists" do
    it "renders unchecked task items as interactive checkboxes" do
      html = helper.render_markdown("- [ ] Buy milk")
      expect(html).to include('type="checkbox"')
      expect(html).not_to include("disabled")
      expect(html).to include('data-action="coplan--checkbox#toggle"')
      expect(html).to include('data-coplan--checkbox-target="checkbox"')
    end

    it "renders checked task items as checked interactive checkboxes" do
      html = helper.render_markdown("- [x] Buy milk")
      expect(html).to include('type="checkbox"')
      expect(html).to include("checked")
      expect(html).not_to include("disabled")
    end

    it "sets data-line-text to the original markdown line" do
      html = helper.render_markdown("- [ ] Buy milk")
      expect(html).to include('data-line-text="- [ ] Buy milk"')
    end

    it "sets data-line-text for checked items" do
      html = helper.render_markdown("- [x] Done task")
      expect(html).to include('data-line-text="- [x] Done task"')
    end

    it "adds task-list class to parent ul" do
      html = helper.render_markdown("- [ ] Item one\n- [x] Item two")
      expect(html).to include('class="task-list"')
    end

    it "adds task-list-item class to li elements" do
      html = helper.render_markdown("- [ ] Item")
      expect(html).to include("task-list-item")
    end

    it "wraps checkbox li contents in a label for clickability" do
      html = helper.render_markdown("- [ ] Click me")
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      label = doc.at_css("li.task-list-item label")
      expect(label).to be_present
      expect(label.at_css('input[type="checkbox"]')).to be_present
    end

    it "handles mixed task and non-task items" do
      md = "- [ ] Task item\n- Regular item"
      html = helper.render_markdown(md)
      expect(html).to include('type="checkbox"')
      expect(html).to include("Regular item")
    end

    it "handles multiple task lists" do
      md = "- [ ] First\n- [x] Second\n\nSome text\n\n- [ ] Third"
      html = helper.render_markdown(md)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      checkboxes = doc.css('input[type="checkbox"]')
      expect(checkboxes.length).to eq(3)
      expect(checkboxes[0]["data-line-text"]).to eq("- [ ] First")
      expect(checkboxes[1]["data-line-text"]).to eq("- [x] Second")
      expect(checkboxes[2]["data-line-text"]).to eq("- [ ] Third")
    end

    it "does not affect regular lists" do
      html = helper.render_markdown("- Item one\n- Item two")
      expect(html).not_to include('type="checkbox"')
      expect(html).not_to include("task-list")
    end

    it "preserves markdown-rendered wrapper class" do
      html = helper.render_markdown("- [ ] Item")
      expect(html).to include('class="markdown-rendered"')
    end

    it "ignores task lines inside fenced code blocks" do
      md = "```\n- [ ] Fake checkbox\n```\n\n- [ ] Real checkbox"
      html = helper.render_markdown(md)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      checkboxes = doc.css('input[type="checkbox"]')
      expect(checkboxes.length).to eq(1)
      expect(checkboxes[0]["data-line-text"]).to eq("- [ ] Real checkbox")
    end

    it "preserves indentation in data-line-text for nested tasks" do
      md = "- [ ] Parent\n  - [ ] Nested child"
      html = helper.render_markdown(md)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      checkboxes = doc.css('input[type="checkbox"]')
      nested = checkboxes.find { |cb| cb["data-line-text"]&.include?("Nested") }
      expect(nested["data-line-text"]).to eq("  - [ ] Nested child")
    end
  end

  describe "#render_markdown data-line attribute" do
    it "sets data-line to the 1-based source line number" do
      md = "# Heading\n\n- [ ] First\n- [x] Second"
      html = helper.render_markdown(md)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      checkboxes = doc.css('input[type="checkbox"]')
      expect(checkboxes.map { |cb| cb["data-line"] }).to eq(%w[3 4])
    end

    it "keeps line numbers accurate across fenced code blocks" do
      md = "```\n- [ ] Fake checkbox\n```\n- [ ] Real checkbox"
      html = helper.render_markdown(md)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      checkboxes = doc.css('input[type="checkbox"]')
      expect(checkboxes.length).to eq(1)
      expect(checkboxes[0]["data-line"]).to eq("4")
    end

    it "keeps line numbers accurate across multiple lists and duplicates" do
      md = "- [ ] TODO\n\nSome text\n\n- [ ] TODO\n- [ ] Other"
      html = helper.render_markdown(md)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      checkboxes = doc.css('input[type="checkbox"]')
      expect(checkboxes.map { |cb| cb["data-line"] }).to eq(%w[1 5 6])
      expect(checkboxes[0]["data-line-text"]).to eq(checkboxes[1]["data-line-text"])
    end

    it "numbers nested tasks by their own source lines" do
      md = "- [ ] Parent\n  - [ ] Nested child"
      html = helper.render_markdown(md)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      nested = doc.css('input[type="checkbox"]').find { |cb| cb["data-line-text"]&.include?("Nested") }
      expect(nested["data-line"]).to eq("2")
    end

    it "strips sourcepos metadata from the rendered output" do
      html = helper.render_markdown("# Heading\n\n- [ ] Task")
      expect(html).not_to include("data-sourcepos")
    end
  end

  describe "renderer/resolver agreement" do
    def interactive_checkboxes(md)
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(md))
      doc.css('input[type="checkbox"]').partition { |cb| cb["data-action"].present? }
    end

    # The invariant the toggle flow rests on: every interactive checkbox's
    # data-line must point at the source line whose rstripped text equals its
    # data-line-text, and the resolver must accept that (old_text, lines) pair.
    def expect_agreement(md)
      interactive, = interactive_checkboxes(md)
      source_lines = md.each_line.map(&:rstrip)
      interactive.each do |cb|
        line = Integer(cb["data-line"])
        expect(source_lines[line - 1]).to eq(cb["data-line-text"])
        resolution = CoPlan::Plans::PositionResolver.call(
          content: md,
          operation: { "op" => "replace_exact", "old_text" => cb["data-line-text"],
                       "new_text" => cb["data-line-text"], "lines" => line }
        )
        expect(resolution.ranges.length).to eq(1)
      end
      interactive
    end

    it "does not pair a checkbox with a task-looking line inside an indented fence" do
      md = " ```\n- [ ] inside indented fence\n ```\n\n- [ ] real task"
      interactive = expect_agreement(md)
      expect(interactive.map { |cb| cb["data-line"] }).to eq(["5"])
    end

    it "does not treat a ~~~ line inside a backtick fence as a fence boundary" do
      md = "```\n~~~\n- [ ] inside fence\n```\n\n- [ ] real task"
      interactive = expect_agreement(md)
      expect(interactive.map { |cb| cb["data-line"] }).to eq(["6"])
    end

    it "does not close a fence with fewer backticks than it was opened with" do
      md = "````\n```\n- [ ] inside fence\n````\n\n- [ ] real task"
      interactive = expect_agreement(md)
      expect(interactive.map { |cb| cb["data-line"] }).to eq(["6"])
    end

    it "does not pair a checkbox with a task-looking line in a 4-space indented code block" do
      md = "Some paragraph\n\n    - [ ] indented code task\n\n- [ ] real task"
      interactive = expect_agreement(md)
      expect(interactive.map { |cb| cb["data-line"] }).to eq(["5"])
    end

    it "does not pair a checkbox with a task-looking line inside an HTML block" do
      md = "<div>\n- [ ] inside html block\n</div>\n\n- [ ] real task"
      interactive = expect_agreement(md)
      expect(interactive.map { |cb| cb["data-line"] }).to eq(["5"])
    end

    it "leaves ordered-list task checkboxes disabled instead of mis-pairing them" do
      md = "1. [ ] ordered task\n\n- [ ] real task"
      interactive, disabled = interactive_checkboxes(md)
      expect_agreement(md)
      expect(interactive.map { |cb| cb["data-line"] }).to eq(["3"])
      expect(disabled.length).to eq(1)
      expect(disabled.first.has_attribute?("disabled")).to be(true)
    end

    it "leaves blockquoted task checkboxes disabled instead of mis-pairing them" do
      md = "> - [ ] quoted task\n\n- [ ] real task"
      interactive, disabled = interactive_checkboxes(md)
      expect_agreement(md)
      expect(interactive.map { |cb| cb["data-line"] }).to eq(["3"])
      expect(disabled.length).to eq(1)
    end

    it "leaves empty-text task checkboxes disabled" do
      md = "- [ ] \n- [ ] real task"
      interactive, = interactive_checkboxes(md)
      expect_agreement(md)
      expect(interactive.map { |cb| cb["data-line"] }).to eq(["2"])
    end

    it "keeps duplicate task lines correctly paired across a gauntlet of divergent constructs" do
      md = <<~MD
        # Tasks

        ```
        - [ ] TODO
        ~~~
        ```

        1. [ ] ordered

        > - [ ] quoted

        - [ ] TODO
        - [ ] TODO

        <div>
        - [ ] TODO
        </div>
      MD
      interactive = expect_agreement(md)
      expect(interactive.map { |cb| cb["data-line"] }).to eq(%w[12 13])
      expect(interactive.map { |cb| cb["data-line-text"] }.uniq).to eq(["- [ ] TODO"])
    end
  end
end
