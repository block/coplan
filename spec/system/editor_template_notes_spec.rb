require "rails_helper"

RSpec.describe "Template notes in the document editor", type: :system do
  let(:author) { create(:coplan_user, email: "template-notes@example.com") }
  let(:source) { "# Decision\n\n<!-- Explain the decision here. -->\n\nVisible prose.\n\n<!--\nFirst hint.\n\nSecond hint with **literal Markdown**.\n-->\n" }
  let(:plan) do
    CoPlan::Plans::Create.call(title: "Template notes", content: source, user: author,
      visibility: "draft", actor_type: "human")
  end
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".document-editor__template-note", count: 2, wait: 20)
  end

  it "preserves comments, fenced examples and other HTML without changing source on mode switches" do
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      import("coplan/rich_document").then(m => {
        const examples = [
          "<!-- one -->\n<!-- two -->\n",
          "  <!--\r\n  Hint\r\n\r\n  **Literal**\r\n  -->\r\n",
          "<!---->", "<!-- -->\n", "<!-- unfinished",
          "```html\n<!-- code example -->\n```\n",
          "    <!-- indented code -->\n",
          "<details><summary>Details</summary>\n\nBody\n\n</details>\n",
          "<details>\n<!-- Keep this HTML block together. -->\n</details>\n",
          "::: {.presentation}\n\n# Slide\n\n<!-- notes: speaker guidance -->\n\n:::\n",
          "<!-->Visible text-->", "<!--->Visible text-->", "<!-- Hint --!>Visible text-->"
        ];
        done(examples.map(source => {
          const doc = m.parseDocument(source), kinds = [];
          doc.forEach(node => kinds.push(node.type.name));
          return { exact: m.serializeDocument(doc) === source, notes: kinds.filter(k => k === "template_note").length };
        }));
      }).catch(error => done({ error: error.message }));
    JS
    expect(result).to all(include("exact" => true))
    expect(result.map { |entry| entry.fetch("notes") }).to eq([ 2, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 ])
    templates = Dir[CoPlan::Engine.root.join("db/default_plan_types/*.md")].map do |path|
      content = File.read(path)
      notes = CoPlan::ContentRegions::Split.call(content).regions
        .select { |region| region.kind == :document }.sum { |region| region.source.scan(/<!--/).length }
      { source: content, notes: notes }
    end
    expect(page.evaluate_async_script(<<~'JS', templates)).to all(eq(true))
      const sources = arguments[0], done = arguments[1];
      import("coplan/rich_document").then(m => done(sources.map(({ source, notes: expected }) => {
        const doc = m.parseDocument(source), notes = [];
        doc.forEach(node => { if (node.type.name === "template_note") notes.push(node); });
        return m.serializeDocument(doc) === source && notes.length === expected;
      })));
    JS
    expect(page).not_to have_content("Markdown block")
    click_button "Raw", exact: true
    expect(find('[aria-label="Markdown source"]').text).to eq(source.strip)
    click_button "Editor", exact: true
    expect(page).to have_css(".document-editor__template-note", text: "Second hint with **literal Markdown**.")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan))
    expect(plan.reload.current_revision).to eq(1)
    expect(plan.current_content).to eq(source)
    expect(page).to have_content("Visible prose.")
    expect(page).not_to have_content("Explain the decision here.")
    expect(page).not_to have_content("First hint.")
    page.save_screenshot(Rails.root.join("tmp", "template-notes-reading.png"))
  end

  it "edits notes in place with multiline input, undo, autosave and muted text in both themes" do
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      colors = page.evaluate_script(<<~'JS')
        (() => {
        const note = document.querySelector('.document-editor__template-note');
        const body = document.querySelector('.document-editor__paper');
        return [getComputedStyle(note).color, getComputedStyle(body).color];
        })()
      JS
      expect(colors.first).not_to eq(colors.last)
      page.save_screenshot(Rails.root.join("tmp", "template-notes-#{theme}.png"))
    end
    note = all(".document-editor__template-note").first
    note.click
    note.send_keys(:end, " More guidance", :enter, "Next line.")
    expect(note).to have_text("Next line.")
    note.send_keys([ mod, "z" ])
    expect(note).not_to have_text("Next line.")
    note.send_keys([ mod, :shift, "z" ])
    expect(note).to have_text("Next line.")
    click_button "Dual", exact: true
    expect(find('[aria-label="Markdown source"]')).to have_text("<!-- Explain the decision here. More guidance\nNext line. -->")
    expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: "All changes saved", visible: :all, wait: 15)
    expect(plan.reload.current_content).to include("<!-- Explain the decision here. More guidance\nNext line. -->", "Visible prose.")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(page).not_to have_content("More guidance")
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".document-editor__template-note", text: "Next line.", wait: 20)
  end

  it "rejects typed and pasted closing markers without exposing note text to readers" do
    note = all(".document-editor__template-note").first
    note.click
    note.send_keys(:end, " --")
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      note.send_keys(">")
      expect(page).to have_css('#coplan-toasts [role="alert"]', text: "would end the template note")
      expect(note.text).to eq("Explain the decision here. --")
      page.save_screenshot(Rails.root.join("tmp", "template-notes-rejected-#{theme}.png"))
    end
    note.send_keys("!", ">")
    expect(note.text).to eq("Explain the decision here. --!")

    page.execute_script(<<~'JS')
      const clipboard = new DataTransfer();
      clipboard.setData("text/plain", " -->Text that must stay hidden");
      document.querySelector('.document-editor__body .ProseMirror').dispatchEvent(
        new ClipboardEvent("paste", { clipboardData: clipboard, bubbles: true, cancelable: true }));
    JS
    expect(note.text).to eq("Explain the decision here. --!")
    expect(page).to have_css('#coplan-toasts [role="alert"]', text: "would end the template note")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("<!-- Explain the decision here. --! -->")
    expect(page).not_to have_content("Explain the decision here.")
    expect(page).not_to have_content("Text that must stay hidden")
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".document-editor__template-note", text: "Explain the decision here. --!", wait: 20)
  end

  it "keeps an empty comment hidden when its first character would abruptly close it" do
    click_button "Raw", exact: true
    find('[aria-label="Markdown source"]').send_keys([ mod, "a" ], "<!---->\n\nVisible prose.")
    click_button "Editor", exact: true
    note = find(".document-editor__template-note")
    note.click
    note.send_keys(">")
    expect(page).to have_css('#coplan-toasts [role="alert"]', text: "would end the template note")
    expect(note.text).to eq("")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to eq("<!---->\n\nVisible prose.")
    expect(page).to have_content("Visible prose.")
    expect(page).not_to have_content("-->")
  end
end
