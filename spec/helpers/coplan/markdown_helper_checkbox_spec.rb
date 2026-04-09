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

    it "adds task-list-item--checked class for checked items" do
      html = helper.render_markdown("- [x] Done")
      expect(html).to include("task-list-item--checked")
    end

    it "does not add task-list-item--checked for unchecked items" do
      html = helper.render_markdown("- [ ] Not done")
      expect(html).not_to include("task-list-item--checked")
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
end
