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
          "<!-->Visible text-->", "<!--->Visible text-->", "<!-- Hint --!>Visible text-->",
          "Visible prose.\n<!-- guidance -->\nFollowing prose.\n",
          "Visible prose.\r\n  <!--\r\n guidance.\r\n -->\r\n",
          "Visible prose.\n<!-- one -->\n<!-- two -->\n",
          "Visible <em>prose</em>.\n<!-- guidance -->\n",
          "- Item\n  <!-- nested note -->\n",
          "> <!-- quoted note -->\n",
          "<script>\n<!-- script comment -->\n</script>\n"
        ];
        done(examples.map(source => {
          const doc = m.parseDocument(source), kinds = [];
          doc.forEach(node => kinds.push(node.type.name));
          return { exact: m.serializeDocument(doc) === source, notes: kinds.filter(k => k === "template_note").length };
        }));
      }).catch(error => done({ error: error.message }));
    JS
    expect(result).to all(include("exact" => true))
    expect(result.map { |entry| entry.fetch("notes") }).to eq([ 2, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 1, 0, 0, 0 ])
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
    expect(page).to have_css("#plan-header .page-header__byline", text: /\bv#{plan.current_revision}\b/)
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp", "template-notes-saved-version-#{theme}.png"))
    end
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(page).not_to have_content("More guidance")
    expect(page).to have_css("#plan-header .page-header__byline", text: /\bv#{plan.current_revision}\b/)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".document-editor__template-note", text: "Next line.", wait: 20)
    expect(page).to have_css("#plan-header .page-header__byline", text: /\bv#{plan.current_revision}\b/)
  end

  it "edits a standalone note immediately after prose without a blank line" do
    initial = "Visible prose.\n<!-- Guidance after prose. -->\nMore prose.\n"
    click_button "Raw", exact: true
    find('[aria-label="Markdown source"]').send_keys([ mod, "a" ], initial)
    click_button "Editor", exact: true
    note = find(".document-editor__template-note", text: "Guidance after prose.")
    expect(page).to have_css(".ProseMirror > p", text: "Visible prose.")
    expect(page).not_to have_content("Markdown block")
    expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(initial)
    note.click
    note.send_keys(:end, " Revised.")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to eq("Visible prose.\n\n<!-- Guidance after prose. Revised. -->\n\nMore prose.\n")
    expect(page).to have_content("Visible prose.")
    expect(page).to have_content("More prose.")
    expect(page).not_to have_content("Guidance after prose.")
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".document-editor__template-note", text: "Guidance after prose. Revised.", wait: 20)
  end

  it "rejects typed and pasted closing markers without exposing note text to readers" do
    note = all(".document-editor__template-note").first
    note.click
    note.send_keys(:end, " --")
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      note.send_keys(">")
      expect(page).to have_css('#coplan-toasts [role="alert"]', text: "would end the comment")
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
    expect(page).to have_css('#coplan-toasts [role="alert"]', text: "would end the comment")
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

  it "creates comments from the text style menu and converts them back to prose or headings" do
    paragraph = find(".ProseMirror > p", text: "Visible prose.")
    paragraph.click
    select "Comment", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".document-editor__template-note", text: "Visible prose.")
    expect(page).to have_select("Paragraph style", selected: "Comment", enable_aria_label: true)
    expect(page).to have_button("Bold", disabled: true)
    click_button "Undo", enable_aria_label: true
    expect(page).to have_css(".ProseMirror > p", text: "Visible prose.")
    click_button "Redo", enable_aria_label: true
    expect(page).to have_css(".document-editor__template-note", text: "Visible prose.")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("<!-- Visible prose. -->")
    expect(page).not_to have_content("Visible prose.")
    visit plan_edit_page_path(plan)
    expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
    note = find(".document-editor__template-note", text: "Visible prose.")
    page.execute_script(<<~'JS', note)
      const form = document.querySelector('form.document-editor')
      const rich = Stimulus.getControllerForElementAndIdentifier(form, 'coplan--editor').richEditor
      rich.selectSource(2) // Keep the model in the heading while the native caret moves.
      window.holdStyleSelection = event => event.stopImmediatePropagation()
      document.addEventListener('selectionchange', window.holdStyleSelection, true)
      const range = document.createRange(); range.selectNodeContents(arguments[0]); range.collapse(false)
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range)
      arguments[0].dispatchEvent(new MouseEvent('mouseup', { bubbles: true }))
    JS
    select "Normal text", from: "Paragraph style", enable_aria_label: true
    page.execute_script("document.removeEventListener('selectionchange', window.holdStyleSelection, true)")
    expect(page).to have_css(".ProseMirror > p", text: "Visible prose.")
    expect(page).to have_css(".ProseMirror > h1", text: "Decision")
    select "Heading 2", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".ProseMirror > h2", text: "Visible prose.")
    select "Comment", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".document-editor__template-note", text: "Visible prose.")
    select "Heading 3", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".ProseMirror > h3", text: "Visible prose.")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("### Visible prose.")
    expect(page).to have_content("Visible prose.")
    expect(page).not_to have_content("Explain the decision here.")
  end

  it "creates an empty comment without typing Markdown and preserves line breaks in converted text" do
    paragraph = find(".ProseMirror > p", text: "Visible prose.")
    paragraph.click
    paragraph.send_keys([ mod, :right ], :enter)
    select "Comment", from: "Paragraph style", enable_aria_label: true
    note = all(".document-editor__template-note").find { |entry| entry.text.empty? }
    note.send_keys("New guidance.", :enter, "Second line.")
    expect(page).to have_select("Paragraph style", selected: "Comment", enable_aria_label: true)
    select "Normal text", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".ProseMirror > p", text: "New guidance.")
    select "Comment", from: "Paragraph style", enable_aria_label: true
    expect(find(".document-editor__template-note", text: "New guidance.").text).to eq("New guidance.\nSecond line.")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("<!-- New guidance.\nSecond line. -->")
    expect(page).not_to have_content("New guidance.")
  end

  it "keeps every line a heading when a multiline comment is saved and reopened" do
    note = find(".document-editor__template-note", text: "First hint.")
    note.click
    select "Heading 2", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".ProseMirror > h2", count: 3)
    expect(page).to have_css(".ProseMirror > h2", text: "First hint.")
    expect(page).to have_css(".ProseMirror > h2", text: "Second hint with **literal Markdown**.")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("## First hint.", "## Second hint with \\*\\*literal Markdown\\*\\*.")
    visit plan_edit_page_path(plan)
    expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
    expect(page).to have_css(".ProseMirror > h2", count: 3)
    expect(page).to have_css(".ProseMirror > h2", text: "First hint.")
    expect(page).to have_css(".ProseMirror > h2", text: "Second hint with **literal Markdown**.")
    expect(page).to have_css(".document-editor__template-note", text: "Explain the decision here.")
  end

  it "converts selected paragraphs together and rejects text that would close the comment" do
    click_button "Raw", exact: true
    find('[aria-label="Markdown source"]').send_keys([ mod, "a" ], "## Heading\n\n**Bold** guidance.\n")
    click_button "Editor", exact: true
    find(".ProseMirror > p", text: "Bold guidance.").send_keys([ mod, "a" ])
    select "Comment", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".document-editor__template-note", count: 2)
    expect(page).to have_css(".document-editor__template-note", text: "Heading")
    expect(page).to have_css(".document-editor__template-note", text: "Bold guidance.")
    expect(page).to have_no_css(".document-editor__template-note strong")
    click_button "Undo", enable_aria_label: true
    expect(page).to have_css(".ProseMirror > h2", text: "Heading")
    expect(page).to have_css(".ProseMirror > p strong", text: "Bold")
    click_button "Raw", exact: true
    find('[aria-label="Markdown source"]').send_keys([ mod, "a" ], "Visible --> text.\n")
    click_button "Editor", exact: true
    find(".ProseMirror > p", text: "Visible --> text.").click
    select "Comment", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".ProseMirror > p", text: "Visible --> text.")
    expect(page).to have_no_css(".document-editor__template-note")
    expect(page).to have_css('#coplan-toasts [role="alert"]', text: "would end the comment")
    expect(page).to have_select("Paragraph style", selected: "Normal text", enable_aria_label: true)
  end

  it "keeps an empty comment hidden when its first character would abruptly close it" do
    click_button "Raw", exact: true
    find('[aria-label="Markdown source"]').send_keys([ mod, "a" ], "<!---->\n\nVisible prose.")
    click_button "Editor", exact: true
    note = find(".document-editor__template-note")
    note.click
    note.send_keys(">")
    expect(page).to have_css('#coplan-toasts [role="alert"]', text: "would end the comment")
    expect(note.text).to eq("")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to eq("<!---->\n\nVisible prose.")
    expect(page).to have_content("Visible prose.")
    expect(page).not_to have_content("-->")
  end

  [ "<!---->", "<!-- \n  -->" ].each do |comment|
    it "keeps the caret inside #{comment.inspect} when switching either editor mode" do
      initial = "#{comment}\n\nVisible prose."
      %w[rich_to_raw raw_to_rich].each do |direction|
        visit plan_edit_page_path(plan)
        click_button "Raw", exact: true
        find('[aria-label="Markdown source"]').send_keys([ mod, "a" ], initial)
        click_button "Editor", exact: true
        note = find(".document-editor__template-note")
        expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
        if direction == "rich_to_raw"
          note.click
          click_button "Raw", exact: true
          find('[aria-label="Markdown source"]').send_keys("Added guidance.")
        else
          click_button "Raw", exact: true
          page.execute_script(<<~'JS', initial.index("-->"))
            const form = document.querySelector('form.document-editor');
            window.Stimulus.getControllerForElementAndIdentifier(form, 'coplan--editor').rawEditor.select(arguments[0]);
          JS
          click_button "Editor", exact: true
          find(".document-editor__template-note").send_keys("Added guidance.")
        end
        click_link "Done"
        expect(page).to have_current_path(plan_page_path(plan), wait: 15)
        expect(plan.reload.current_content).to eq(initial.sub("-->", "Added guidance.-->"))
        expect(page).to have_content("Visible prose.")
        expect(page).not_to have_content("Added guidance.")
      end
    end
  end

  it "removes an emptied comment with Backspace and places the caret in the preceding content" do
    note = all(".document-editor__template-note").first
    note.click
    note.send_keys([ mod, "a" ], :backspace)
    expect(note.text).to eq("")
    note.send_keys(:backspace)
    expect(page).to have_css(".document-editor__template-note", count: 1)
    expect(page.evaluate_script(<<~'JS')).to eq([ "Decision", "Decision".length ])
      (() => {
        const selection = window.getSelection()
        return [selection.anchorNode.parentElement.closest("h1")?.textContent, selection.anchorOffset]
      })()
    JS
    find(".ProseMirror > h1").send_keys([ mod, "z" ])
    expect(page).to have_css(".document-editor__template-note", count: 2)
    expect(all(".document-editor__template-note").first.text).to eq("")
    all(".document-editor__template-note").first.send_keys([ mod, :shift, "z" ])
    expect(page).to have_css(".document-editor__template-note", count: 1)
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp", "empty-comment-deleted-#{theme}.png"))
    end
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).not_to include("<!-- -->", "Explain the decision here.")
    expect(plan.current_content).to include("# Decision", "Visible prose.", "<!--\nFirst hint.")
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".document-editor__template-note", count: 1, wait: 20)
  end

  it "removes an empty leading comment through native backward deletion and moves to the next paragraph" do
    click_button "Raw", exact: true
    find('[aria-label="Markdown source"]').send_keys([ mod, "a" ], "<!-- -->\n\nFollowing prose.\n")
    click_button "Editor", exact: true
    note = find(".document-editor__template-note")
    note.click
    expect(page.evaluate_script(<<~'JS')).to be(false)
      document.querySelector('.document-editor__body .ProseMirror').dispatchEvent(new InputEvent('beforeinput', {
        inputType: 'deleteContentBackward', bubbles: true, cancelable: true
      }))
    JS
    expect(page).to have_no_css(".document-editor__template-note")
    expect(page.evaluate_script('window.getSelection().anchorNode.parentElement.closest("p")?.textContent')).to eq("Following prose.")
  end

  it "keeps formatting shortcuts and boundary deletion from turning notes into visible prose" do
    note = all(".document-editor__template-note").first
    note.click
    expect(page).to have_css('select[aria-label="Paragraph style"]:enabled')
    expect(page).to have_button("Insert code block", disabled: true)
    %w[0 1 2 3].each { |key| note.send_keys([ mod, :alt, key ]) }
    %w[backspace delete].each do |key|
      page.execute_script(<<~'JS', note, key, source.index("Explain the decision here."))
        const backward = arguments[1] === 'backspace';
        const form = document.querySelector('form.document-editor');
        const editor = window.Stimulus.getControllerForElementAndIdentifier(form, 'coplan--editor').richEditor;
        editor.selectSource(arguments[2] + (backward ? arguments[0].textContent.length : 0));
        // Hold the model at the opposite end while the browser caret moves.
        window.delayTemplateNoteSelection = event => event.stopImmediatePropagation();
        document.addEventListener('selectionchange', window.delayTemplateNoteSelection, true);
        const range = document.createRange(); range.selectNodeContents(arguments[0]); range.collapse(backward);
        const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      JS
      expect(page.evaluate_script(<<~'JS', key)).to be(false)
        document.querySelector('.document-editor__body .ProseMirror').dispatchEvent(new InputEvent('beforeinput', {
          inputType: arguments[0] === 'backspace' ? 'deleteContentBackward' : 'deleteContentForward',
          bubbles: true, cancelable: true
        }));
      JS
      page.driver.browser.action.send_keys(key.to_sym).perform
      page.execute_script("document.removeEventListener('selectionchange', window.delayTemplateNoteSelection, true)")
      expect(page).to have_css(".document-editor__template-note", text: "Explain the decision here.")
      expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(source)
    end

    paragraph = find(".document-editor__body .ProseMirror > p", text: "Visible prose.")
    page.execute_script(<<~'JS', note, paragraph)
      const range = document.createRange();
      range.setStart(arguments[0].firstChild, 0);
      range.setEnd(arguments[1].firstChild, 3);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
    JS
    expect(page).to have_css('select[aria-label="Paragraph style"]:enabled')
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
