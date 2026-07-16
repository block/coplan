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
    def checkboxes_for(md)
      html = helper.render_markdown(md)
      Nokogiri::HTML::DocumentFragment.parse(html).css('input[type="checkbox"]')
    end

    it "sets data-line to the 1-based source line number" do
      checkboxes = checkboxes_for("# Heading\n\n- [ ] First\n- [x] Second")
      expect(checkboxes.map { |cb| cb["data-line"] }).to eq(%w[3 4])
    end

    it "keeps line numbers accurate across fenced code blocks" do
      checkboxes = checkboxes_for("```\n- [ ] Fake checkbox\n```\n- [ ] Real checkbox")
      interactive = checkboxes.reject { |cb| cb["disabled"] }
      expect(interactive.length).to eq(1)
      expect(interactive[0]["data-line"]).to eq("4")
    end

    it "keeps line numbers accurate for duplicate task lines" do
      checkboxes = checkboxes_for("- [ ] TODO\n\nSome text\n\n- [ ] TODO\n- [ ] Other")
      expect(checkboxes.map { |cb| cb["data-line"] }).to eq(%w[1 5 6])
      expect(checkboxes[0]["data-line-text"]).to eq(checkboxes[1]["data-line-text"])
    end

    it "numbers nested tasks by their own source lines" do
      checkboxes = checkboxes_for("- [ ] Parent\n  - [ ] Nested child")
      nested = checkboxes.find { |cb| cb["data-line-text"]&.include?("Nested") }
      expect(nested["data-line"]).to eq("2")
    end

    it "handles indented code blocks that contain task-shaped lines" do
      md = "Intro:\n\n    - [ ] not a task\n\n- [ ] Real task"
      checkboxes = checkboxes_for(md)
      interactive = checkboxes.reject { |cb| cb["disabled"] }
      expect(interactive.map { |cb| cb["data-line"] }).to eq(%w[5])
    end

    it "leaves ordered-list tasks non-interactive (toggle endpoint rejects them)" do
      checkboxes = checkboxes_for("1. [ ] Ordered task\n\n- [ ] Bullet task")
      interactive = checkboxes.reject { |cb| cb["disabled"] }
      expect(interactive.map { |cb| cb["data-line-text"] }).to eq(["- [ ] Bullet task"])
    end

    it "strips data-sourcepos from the rendered output" do
      html = helper.render_markdown("# Heading\n\n- [ ] Task\n\nParagraph.")
      expect(html).not_to include("data-sourcepos")
    end

    it "does not emit data-sourcepos in non-interactive renders" do
      html = helper.render_markdown("- [ ] Task", interactive: false)
      expect(html).not_to include("data-sourcepos")
      expect(html).not_to include("data-line")
    end

    it "keeps every interactive checkbox's line and text in agreement (gauntlet)" do
      md = <<~MD
        # Plan

        - [ ] TODO
        - [ ] TODO
        - [ ] Deploy
        - [ ] Deploy to staging

        ```
        - [ ] fenced fake
        ~~~
        - [ ] nested fence fake
        ```

        1. [ ] ordered task

        > - [ ] quoted task

        - [x] Final real task
      MD

      source_lines = md.each_line.map(&:rstrip)
      checkboxes = checkboxes_for(md)
      interactive = checkboxes.reject { |cb| cb["disabled"] }
      expect(interactive).not_to be_empty

      interactive.each do |cb|
        line = Integer(cb["data-line"])
        expect(source_lines[line - 1]).to eq(cb["data-line-text"])
        expect(cb["data-line-text"]).to match(CoPlan::MarkdownHelper::TASK_LINE_PATTERN)
      end
    end
  end
end
