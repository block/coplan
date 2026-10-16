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
    expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
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

  it "scopes Select All to the current note when replacing guidance" do
    note = all(".document-editor__template-note").first
    note.click
    page.driver.browser.action.key_down(mod).send_keys("a").key_up(mod).send_keys("Revised guidance.").perform
    expect(note.text).to eq("Revised guidance.")
    expect(page).to have_css(".ProseMirror > h1", text: "Decision")
    expect(page).to have_css(".ProseMirror > p", text: "Visible prose.")
    expect(page).to have_css(".document-editor__template-note", count: 2)
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to eq(source.sub("Explain the decision here.", "Revised guidance."))
    expect(page).not_to have_content("Revised guidance.")
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".document-editor__template-note", text: "Revised guidance.", wait: 20)
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

  it "keeps formatting commands and boundary deletion from turning notes into visible prose" do
    note = all(".document-editor__template-note").first
    note.click
    expect(page).to have_css('select[aria-label="Paragraph style"][disabled]')
    expect(page).to have_button("Insert code block", disabled: true)
    %w[0 1 2 3].each { |key| note.send_keys([ mod, :alt, key ]) }
    page.execute_script(<<~'JS', note)
      const range = document.createRange(); range.setStart(arguments[0].firstChild, 0); range.collapse(true);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
    JS
    page.driver.browser.action.send_keys(:backspace).perform
    expect(note.text).to eq("Explain the decision here.")
    expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(source)

    paragraph = find(".document-editor__body .ProseMirror > p", text: "Visible prose.")
    page.execute_script(<<~'JS', note, paragraph)
      const range = document.createRange();
      range.setStart(arguments[0].firstChild, 0);
      range.setEnd(arguments[1].firstChild, 3);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
    JS
    expect(page).to have_css('select[aria-label="Paragraph style"][disabled]')
    paragraph.click
    expect(page).to have_css('select[aria-label="Paragraph style"]:enabled')
    select "Heading 2", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".ProseMirror > h2", text: "Visible prose.")
    expect(note.text).to eq("Explain the decision here.")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("<!-- Explain the decision here. -->", "## Visible prose.")
    expect(page).not_to have_content("Explain the decision here.")
  end

  it "matches comment highlights, caret focus and new selections against visible prose only" do
    content = "# Decision\n\n<!-- Shared phrase. -->\n\n" +
      (1..20).map { |index| "Intro paragraph #{index}.\n\n" }.join +
      "Shared phrase.\n\nShared phrase.\n\n" +
      (1..20).map { |index| "Later paragraph #{index}.\n\n" }.join + "<!-- Another hint. -->\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    thread = create(:comment_thread, plan: plan, created_by_user: author,
      anchor_text: "Shared phrase.", anchor_occurrence: 2)
    create(:comment, comment_thread: thread, author_id: author.id, body_markdown: "Review the visible paragraph")
    expect(thread.anchor_occurrence_index).to eq(0)
    visit plan_page_path(plan)
    paragraph = all("#plan-content-body p", text: "Shared phrase.").first
    page.execute_script("window.scrollBy(0, arguments[0].getBoundingClientRect().top - 160)", paragraph)
    find(".site-nav__plan-context--visible .site-nav__edit").click
    expect(page).to have_css(".document-editor__template-note", count: 2, wait: 20)
    expect(page).to have_css(".ProseMirror > p mark[data-thread-id='comment_thread_#{thread.id}']", text: "Shared phrase.")
    expect(page).not_to have_css(".document-editor__template-note mark")
    expect(page.evaluate_script('window.getSelection().anchorNode.parentElement.closest(".document-editor__template-note")')).to be_nil
    expect(page.evaluate_script('window.getSelection().anchorNode.parentElement.closest("p")?.textContent')).to eq("Shared phrase.")

    note = all(".document-editor__template-note").first
    page.execute_script(<<~'JS', note)
      const range = document.createRange(); range.selectNodeContents(arguments[0]);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      arguments[0].dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
    JS
    expect(page).not_to have_css(".comment-popover", visible: true)
    paragraph = all(".ProseMirror > p", text: "Shared phrase.").last
    page.execute_script(<<~'JS', paragraph)
      const range = document.createRange(); range.selectNodeContents(arguments[0]);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      arguments[0].dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
    JS
    find(".comment-popover button", text: "Comment").click
    expect(page).to have_css("#new-comment-form", visible: true)
    expect(find('#new-comment-form input[name="comment_thread[anchor_occurrence]"]', visible: :all).value).to eq("2")
  end

  it "keeps authored HTML commentable when it shares the note CSS class" do
    content = "# Visible HTML\n\n<div class=\"document-editor__template-note\" data-coplan-template-note>Visible HTML guidance.</div>\n\nVisible prose.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Visible HTML guidance.")
    create(:comment, comment_thread: thread, author_id: author.id, body_markdown: "Review the visible HTML")
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-content-body .document-editor__template-note mark[data-thread-id='comment_thread_#{thread.id}']", text: "Visible HTML guidance.")
    expect(page).not_to have_css("#plan-content-body [data-coplan-template-note]")
    html = find("#plan-content-body .document-editor__template-note")
    page.execute_script(<<~'JS', html)
      const range = document.createRange(); range.selectNodeContents(arguments[0]);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      arguments[0].dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
    JS
    find(".comment-popover button", text: "Comment").click
    expect(page).to have_css("#new-comment-form", visible: true)
    expect(find('#new-comment-form input[name="comment_thread[anchor_text]"]', visible: :all).value).to eq("Visible HTML guidance.")
  end

  {
    "a note" => "<!-- Pasted guidance. -->",
    "a document containing a note" => "# Pasted heading\n\nNew prose.\n\n<!-- Pasted guidance. -->\n"
  }.each do |label, pasted|
    it "keeps #{label} standalone when pasted after an unchanged paragraph without a final newline" do
      click_button "Raw", exact: true
      find('[aria-label="Markdown source"]').send_keys([ mod, "a" ], "Existing prose.")
      click_button "Editor", exact: true
      click_link "Done"
      expect(page).to have_current_path(plan_page_path(plan), wait: 15)
      expect(plan.reload.current_content).to eq("Existing prose.")
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".document-editor__body .ProseMirror > p", text: "Existing prose.", wait: 20)
      expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
      page.execute_script(<<~'JS', pasted)
        const form = document.querySelector('form.document-editor');
        const editor = window.Stimulus.getControllerForElementAndIdentifier(form, 'coplan--editor').richEditor;
        // A synthetic paste has no keydown to synchronize the native selection.
        editor.selectSource("Existing prose.".length, "Existing prose.".length);
        const clipboard = new DataTransfer(); clipboard.setData("text/plain", arguments[0]);
        document.querySelector('.document-editor__body .ProseMirror').dispatchEvent(
          new ClipboardEvent("paste", { clipboardData: clipboard, bubbles: true, cancelable: true }));
      JS
      expect(page).to have_css(".document-editor__template-note", text: "Pasted guidance.")
      click_link "Done"
      expect(page).to have_current_path(plan_page_path(plan), wait: 15)
      expect(plan.reload.current_content).to eq("Existing prose.\n\n#{pasted}")
      expect(page).not_to have_content("Pasted guidance.")
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".document-editor__template-note", text: "Pasted guidance.", wait: 20)
    end
  end
end
