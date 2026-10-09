require "rails_helper"

RSpec.describe "Human plan editing", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Editable Plan", visibility: "published", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: "# Editable Plan\n\nFirst draft body.\n",
      actor_type: "human", actor_id: author.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")
  end

  before { sign_in(author) }

  def editor
    find('.ProseMirror[contenteditable="true"]', wait: 20)
  end

  def save_now
    modifier = RUBY_PLATFORM.include?("darwin") ? :meta : :control
    page.driver.browser.action.key_down(modifier).send_keys("s").key_up(modifier).perform
  end

  it "edits and formats the actual document, saving without navigation" do
    visit plan_edit_page_path(plan)
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Revised body from the browser.")
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ])
    click_button "Bold"
    expect(page).to have_css(".ProseMirror strong", text: "Revised body")
    save_now
    expect(page).to have_content("All changes saved · v2")
    expect(page).to have_current_path(plan_edit_page_path(plan))
    expect(plan.reload.current_content).to include("**Revised body from the browser.**")
    expect(plan.current_plan_version.actor_type).to eq("human")
  end

  it "edits the title while retaining tags without metadata controls" do
    plan.update!(tag_names: [ "security", "api-design" ])
    visit plan_edit_page_path(plan)
    editor
    # Use native selection/typing: Capybara's programmatic input.select() can
    # lose its range when Chrome refocuses the element before send_keys.
    modifier = RUBY_PLATFORM.include?("darwin") ? :meta : :control
    find("#plan-header .inline-editor__title").send_keys([ modifier, "a" ], "Renamed In Editor")
    expect(page).not_to have_css(".document-editor__menu")
    expect(page).not_to have_field("plan_tag_names")
    expect(page).not_to have_field("change_summary", visible: :all)
    save_now
    expect(page).to have_content("All changes saved · v1")
    expect(plan.reload.title).to eq("Renamed In Editor")
    expect(plan.tag_names).to contain_exactly("security", "api-design")
  end

  it "round trips untouched Markdown including unsupported constructs exactly" do
    visit plan_edit_page_path(plan)
    editor
    fixtures = [
      "# Heading\n\nSome **bold** and _italic_ text.\n",
      "# A\n\n```mermaid\ngraph TD; A-->B\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n",
      "[hello][ref]\n\n[ref]: https://example.com\n",
      "<details><summary>Note</summary>raw HTML</details>\n",
      "- [ ] task\n\nFootnote[^1]\n\n[^1]: footnote\n",
      "~~Strike~~ and [@sam](mention:sam)\n",
      "A\n\nB", "## Heading\nparagraph\n\n- A\n- B\n"
    ]
    results = page.evaluate_async_script(<<~'JS', fixtures)
      const [fixtures, done] = arguments;
      import("coplan/rich_document").then(m => done(fixtures.map(source => m.serializeDocument(m.parseDocument(source)))));
    JS
    expect(results).to eq(fixtures)
  end

  it "edits cited prose and lists without Markdown cards, retaining citations on save" do
    source = "A catalog price.[^catalog-shape] Inline `[^literal]` stays code.\n\n" \
      "- A client rule.[^client]\n- Another rule.\n\n[^catalog-shape]: Catalog details.\n[^client]: Client details.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    editor
    expect(page).to have_css(".ProseMirror p", text: "A catalog price.")
    expect(page).to have_css(".ProseMirror li .document-editor__footnote", text: "[client]")
    expect(page).to have_css(".ProseMirror code", text: "[^literal]")
    expect(page).to have_no_css(".document-editor__block-header", text: "Markdown block")
    expect(page).to have_no_css(".document-editor__block-header", text: "References", visible: true)
    expect(page).to have_no_css(".document-editor__block-preview pre", text: "[^catalog-shape]: Catalog details.", visible: true)
    original = page.evaluate_async_script(<<~'JS', source)
      const [source, done] = arguments;
      import("coplan/rich_document").then(m => done(m.serializeDocument(m.parseDocument(source))));
    JS
    expect(original).to eq(source)
    page.execute_script(<<~JS)
      const form = document.querySelector('form.document-editor')
      const view = window.Stimulus.getControllerForElementAndIdentifier(form, 'coplan--editor').richEditor.view
      let paragraph, item
      view.state.doc.descendants((node, pos) => {
        if (node.isText && node.text.includes('A catalog price.')) paragraph = pos
        if (node.isText && node.text === 'A client rule.') item = pos
      })
      view.dispatch(view.state.tr.insertText('Resolved client rule.', item, item + 'A client rule.'.length))
      view.dispatch(view.state.tr.insertText('Resolved catalog price.', paragraph, paragraph + 'A catalog price.'.length))
    JS
    save_now
    expect(page).to have_content("All changes saved · v3")
    expect(plan.reload.current_content).to include("Resolved catalog price.[^catalog-shape]", "Resolved client rule.[^client]", "`[^literal]`")
    expect(plan.current_content).to end_with("[^catalog-shape]: Catalog details.\n[^client]: Client details.\n")
  end

  it "edits a whole presentation in one Markdown field, preserving its wrapping region" do
    source = "Before the deck.\n\n::: {.presentation #review theme=\"graphite\"}\n\n# Review\n\nOpening slide.\n\n---\n\n## Decision\n\n- Ship it.\n\n:::\n\nAfter the deck.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    editor
    expect(page).to have_field("Presentation Markdown", enable_aria_label: true)
    expect(page).to have_no_button("Edit boundary")
    expect(page).to have_no_css(".document-editor__block-header", text: "Markdown block", visible: true)
    field = find('[aria-label="Presentation Markdown"]')
    field.fill_in with: field.value.sub("Opening slide.", "Updated slide.")
    within(".document-editor__content-block") do
      expect(page).to have_css(".document-editor__presentation-label svg")
      click_button "Preview", exact: true
      expect(page).to have_css(".deck-slide", text: "Updated slide.")
      expect(page).to have_no_field("Presentation Markdown", enable_aria_label: true)
      find('button[aria-label="Next slide"]').click
      expect(page).to have_css(".deck-slide", text: "Decision")
      click_button "Edit Markdown"
      expect(page).to have_field("Presentation Markdown", enable_aria_label: true, with: /Updated slide/)
    end
    save_now
    expect(page).to have_content("All changes saved · v3")
    expect(plan.reload.current_content).to eq(source.sub("Opening slide.", "Updated slide."))
  end

  it "refreshes whole presentation blocks after source edits and retains copied citations" do
    visit plan_edit_page_path(plan)
    editor
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      Promise.all([import("coplan/rich_document"), import("prosemirror-model")]).then(([m, model]) => {
        const host = document.createElement("div");
        const open = "::: {.presentation}\n\n# Review\n";
        const closed = open + "\n:::\n";
        const rich = m.createRichDocument(host, open, () => {});
        rich.update(closed);
        const presentations = host.querySelectorAll('[aria-label="Presentation Markdown"]').length;
        rich.update(open);
        const unclosed = host.querySelectorAll('[aria-label="Presentation Markdown"]').length;
        const windows = m.serializeDocument(m.parseDocument(closed.replaceAll('\n', '\r\n')));
        rich.update('Cited prose.[^catalog]');
        const copy = document.createElement('div');
        copy.append(host.querySelector('p').cloneNode(true));
        const pasted = model.DOMParser.fromSchema(rich.view.state.schema).parse(copy);
        const citation = m.serializeDocument(pasted);
        const plain = pasted.textBetween(0, pasted.content.size);
        rich.destroy();
        done({ presentations, unclosed, windows, citation, plain });
      });
    JS
    expect(result).to include("presentations" => 1, "unclosed" => 0,
      "windows" => "::: {.presentation}\r\n\r\n# Review\r\n\r\n:::\r\n",
      "citation" => "Cited prose.[^catalog]", "plain" => "Cited prose.[^catalog]")
  end

  it "edits citations in a dialog while keeping definitions out of the body" do
    source = "A catalog price.[^catalog] More context.[^other]\n\n[^catalog]: Catalog details.\n    A second line.\n\n    A second paragraph.\n[^other]: Keep this definition.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    editor
    click_button "Edit citation catalog", enable_aria_label: true
    expect(page).to have_css('dialog[open]', text: 'Citation: catalog')
    expect(find('#coplan-citation-body').value).to eq("Catalog details.\nA second line.\n\nA second paragraph.")
    fill_in "Citation text and source links", with: "Updated [Catalog source](https://example.com/catalog).\nMore detail."
    click_button "Save citation"
    expect(page).to have_no_css('dialog[open]')
    expect(plan.reload.current_content).to include("[^catalog]: Updated [Catalog source](https://example.com/catalog).\n    More detail.", "[^other]: Keep this definition.")
    expect(page).to have_no_css('.ProseMirror pre', text: '[^catalog]:', visible: true)
    click_button "Edit citation catalog", enable_aria_label: true
    expect(find('#coplan-citation-body').value).to include('Updated [Catalog source]')
    click_button "Cancel"
  end

  it "keeps a list rich when it contains a table and edits just that table" do
    source = "- First item.\n\n  | Name | State |\n  | --- | --- |\n  | Alpha | Ready |\n\n- Second item.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    editor
    expect(page).to have_css('.ProseMirror > ul > li', count: 2)
    expect(page).to have_css('.ProseMirror li .document-editor__block-preview table td', text: 'Ready')
    click_button "Edit table"
    field = find('[aria-label="Table Markdown"]')
    expect(field.value).not_to include('First item')
    field.fill_in with: field.value.sub('Ready', 'Done')
    save_now
    expect(page).to have_content('All changes saved · v3')
    expect(plan.reload.current_content).to include('First item.', 'Second item.', '| Alpha | Done |')
    expect(plan.current_content).not_to include('Ready')
  end

  it "keeps quoted tables in their quote and exposes their own source range" do
    source = "> Explanation.\n>\n> | Name | Status |\n> | --- | --- |\n> | Alpha | Ready |\n\nAfter.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    editor
    expect(page).to have_css('.ProseMirror blockquote table', text: 'Ready')
    click_button 'Edit table'
    field = find_field('Table Markdown', enable_aria_label: true)
    expect(field.value).not_to include('>')
    field.fill_in with: field.value.sub('Ready', 'Done')
    save_now
    expect(page).to have_content('All changes saved · v3')
    expect(plan.reload.current_content).to include('> | Alpha | Done |', '> Explanation.', 'After.')
    expect(plan.current_content).not_to include('> >')
    range_source = page.evaluate_script(<<~'JS')
      (() => {
        const editor = Stimulus.getControllerForElementAndIdentifier(document.querySelector('form.document-editor'), 'coplan--editor').richEditor;
        let position; editor.view.state.doc.descendants((node, pos) => { if (node.attrs.kind === 'table') position = pos; });
        const range = editor.sourceRange(position);
        return range ? editor.content().slice(range.from, range.to) : null;
      })()
    JS
    expect(range_source).to include('| Alpha | Done |')
  end

  it "edits iframe settings and keeps disallowed URLs from loading" do
    source = '::: {.iframe src="https://unapproved.example.com/report" title="Report" width="100%" height="480" /}' + "\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    editor
    expect(page).to have_field('Embedded page URL', enable_aria_label: true, with: 'https://unapproved.example.com/report')
    expect(page).to have_content('Embedded page unavailable')
    expect(page).to have_no_css('.document-editor__block-preview iframe')
    fill_in 'Embedded page height', enable_aria_label: true, with: '600'
    fill_in 'Embedded page title', enable_aria_label: true, with: 'Updated report'
    save_now
    expect(page).to have_content('All changes saved · v3')
    expect(plan.reload.current_content).to include('height="600"', 'title="Updated report"')
  end

  it "inserts an editable presentation from the content menu at the caret" do
    visit plan_edit_page_path(plan)
    editor
    find(".ProseMirror > p", match: :first).click
    click_button "Insert content", enable_aria_label: true
    expect(page).to have_button("Presentation", exact: true)
    expect(page).to have_button("Embed", exact: true)
    click_button "Presentation", exact: true
    expect(page).to have_no_css("#coplan-insert-content:popover-open")
    field = find('[aria-label="Presentation Markdown"]:focus')
    field.fill_in with: "# New presentation\n\nA useful slide."
    save_now
    expect(page).to have_content("All changes saved · v2")
    expect(plan.reload.current_content).to include("::: {.presentation}", "# New presentation", "A useful slide.", ":::")
    find('[aria-label="Remove presentation"]').click
    page.execute_script("window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=\"coplan--editor\"]'), 'coplan--editor').richEditor.command('undo')")
    expect(page).to have_field("Presentation Markdown", enable_aria_label: true, with: /A useful slide/)
  end

  it "adds content after a selected presentation without replacing it" do
    source = "::: {.presentation}\n\n# Existing deck\n\n:::\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    editor
    page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      import('prosemirror-state').then(({NodeSelection}) => {
        const view = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~="coplan--editor"]'), 'coplan--editor').richEditor.view;
        view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, 0)));
        done();
      });
    JS
    click_button "Insert content", enable_aria_label: true
    click_button "Embed", exact: true
    expect(page).to have_field("Presentation Markdown", enable_aria_label: true, with: /Existing deck/)
    expect(page).to have_css('[data-embed-attribute="src"]:focus')
  end

  it "focuses a newly inserted iframe and lets removal be undone" do
    source = '::: {.iframe src="https://unapproved.example.com/first" title="First" /}' + "\n\nEnd.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    editor
    find(".ProseMirror > p", text: "End.").click
    click_button "Insert content", enable_aria_label: true
    click_button "Embed", exact: true
    expect(page).to have_css('[data-embed-attribute="src"]', count: 2)
    expect(page.evaluate_script('document.activeElement.value')).to eq('https://')
    focused = find('[data-embed-attribute="src"]:focus')
    focused.fill_in with: 'https://unapproved.example.com/second'
    block = focused.find(:xpath, 'ancestor::div[contains(@class,"document-editor__block")]', match: :first)
    block.click_button "Remove embedded page", enable_aria_label: true
    expect(page).to have_css('[data-embed-attribute="src"]', count: 1)
    click_button "Undo", enable_aria_label: true
    expect(page).to have_css('[data-embed-attribute="src"]', count: 2)
  end

  it "opens back-matter citations for whole content blocks in both themes" do
    source = "::: {.presentation}\n\n# Review\n\nDecision.[^catalog]\n\n:::\n\n" +
      '::: {.iframe src="https://unapproved.example.com/report" title="Report" /}' + "\n\n[^catalog]: Catalog details.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    editor
    %w[light dark].each do |theme|
      page.execute_script('document.documentElement.dataset.theme = arguments[0]', theme)
      expect(page).to have_field("Presentation Markdown", enable_aria_label: true)
      expect(page).to have_field("Embedded page URL", enable_aria_label: true)
      page.save_screenshot(Rails.root.join("tmp/editor-tryout/content-blocks-#{theme}.png"))
      click_button "Edit reference catalog", enable_aria_label: true
      expect(page).to have_css('dialog[open]', text: 'Citation: catalog')
      expect(find('#coplan-citation-body').value).to eq('Catalog details.')
      page.save_screenshot(Rails.root.join("tmp/editor-tryout/citation-#{theme}.png"))
      click_button "Cancel"
    end
  end

  it "leaves unclosed or unknown presentation markers visible and code examples literal" do
    visit plan_edit_page_path(plan)
    editor
    fixtures = [
      "::: {.presentation}\n\n# Unclosed\n",
      "::: {.unknown}\n\nText\n\n:::\n",
      "```markdown\n::: {.presentation}\n\n# Example\n\n:::\n```\n",
      "> ::: {.presentation}\n>\n> quoted\n>\n> :::\n"
    ]
    results = page.evaluate_async_script(<<~'JS', fixtures)
      const [fixtures, done] = arguments;
      import("coplan/rich_document").then(m => done(fixtures.map(source => {
        const doc = m.parseDocument(source);
        let boundaries = 0;
        doc.forEach(node => { if (node.attrs.kind === "presentation") boundaries++; });
        return { source: m.serializeDocument(doc), boundaries };
      })));
    JS
    expect(results).to eq(fixtures.map { |source| { "source" => source, "boundaries" => 0 } })
  end

  it "keeps untouched blocks exact when editing beside tables and Mermaid" do
    visit plan_edit_page_path(plan)
    editor
    source = "# Heading\n\nOriginal body.\n\n```mermaid\ngraph TD; A-->B\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
    result = page.evaluate_async_script(<<~'JS', source)
      const [source, done] = arguments;
      import("coplan/rich_document").then(m => {
        const host = document.createElement("div");
        const rich = m.createRichDocument(host, source, () => {});
        let position;
        rich.view.state.doc.descendants((node, pos) => { if (node.isText && node.text === "Original body.") position = pos; });
        rich.view.dispatch(rich.view.state.tr.insertText("Revised", position, position + 8));
        const result = rich.content(); rich.destroy(); done(result);
      });
    JS
    expect(result).to include("Revised body.")
    expect(result).to start_with("# Heading\n\n")
    expect(result).to end_with("```mermaid\ngraph TD; A-->B\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n")
  end

  it "discards unsaved edits on reload and retains saved edits" do
    visit plan_edit_page_path(plan)
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Saved edit")
    save_now
    expect(page).to have_content("All changes saved · v2")
    page.execute_script('window.originalFetch = window.fetch; window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : window.originalFetch(url, options)')
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Unsaved edit")
    save_now
    expect(page).to have_css('.document-editor__close-inline[data-state="error"][aria-label="Retry sync"]')
    page.refresh
    expect(editor).to have_text("Saved edit")
    expect(editor).not_to have_text("Unsaved edit")
    expect(page).not_to have_content("Recovered an unsaved draft")
    expect(plan.reload.current_revision).to eq(2)
  end

  it "lets reload discard a draft after a failed save" do
    visit plan_edit_page_path(plan)
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Keep this unsaved draft")
    page.execute_script(<<~'JS')
      const originalFetch = window.fetch;
      window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : originalFetch(url, options);
    JS
    save_now
    expect(page).to have_css('.document-editor__close-inline[data-state="error"][aria-label="Retry sync"]')
    expect(plan.reload.current_revision).to eq(1)
    page.refresh
    expect(editor).to have_text("First draft body.")
    expect(editor).not_to have_text("Keep this unsaved draft")
    expect(plan.reload.current_revision).to eq(1)
  end

  it "lets an overlapping edit be discarded by reloading" do
    visit plan_edit_page_path(plan)
    editor
    page.execute_script('window.originalFetch = window.fetch; window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : window.originalFetch(url, options)')
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "My retained draft")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Intervening content", base_revision: 1,
      actor_type: "local_agent", actor_id: author.id)
    expect(page).to have_css('.document-editor__close-inline[data-state="conflict"][aria-label="Conflict — reload document"]', wait: 10)
    expect(editor).to have_text("My retained draft")
    expect(plan.reload.current_content).to eq("Intervening content")
    page.execute_script('window.fetch = window.originalFetch')
    find('.document-editor__close-inline[data-state="conflict"]').click
    expect(editor).to have_text("Intervening content", wait: 10)
    expect(plan.reload.current_revision).to eq(2)
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan))
    expect(plan.reload.edit_lease).to be_nil
  end

  it "autosaves and uses the same paragraph typography as reading view" do
    visit plan_page_path(plan)
    reading = page.evaluate_script('(() => { const s = getComputedStyle(document.querySelector(".markdown-rendered p")); return [s.fontSize, s.lineHeight, s.marginBottom] })()')
    visit plan_edit_page_path(plan)
    editor
    writing = page.evaluate_script('(() => { const s = getComputedStyle(document.querySelector(".ProseMirror p")); return [s.fontSize, s.lineHeight, s.marginBottom] })()')
    expect(writing).to eq(reading)
    expect(writing.last).not_to eq("0px")
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Autosaved from typing")
    expect(page).to have_content("All changes saved · v2", wait: 10)
    expect(plan.reload.current_content).to include("Autosaved from typing")
    expect(plan.edit_lease).to be_nil
    click_link "Done"
    expect(page).to have_css(".markdown-rendered", text: "Autosaved from typing")
    page.refresh
    expect(page).to have_css(".markdown-rendered", text: "Autosaved from typing")
  end

  it "handles Command and Control formatting, undo, redo and list shortcuts" do
    visit plan_edit_page_path(plan)
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Keyboard text")
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ])
    [ :meta, :control ].each do |modifier|
      editor.send_keys([ modifier, "b" ])
      expect(page).to have_css(".ProseMirror strong", text: "Keyboard text")
      expect(page).to have_css('[aria-label="Bold"][aria-pressed="true"]')
      editor.send_keys([ modifier, "z" ])
      expect(page).not_to have_css(".ProseMirror strong")
      editor.send_keys([ modifier, :shift, "z" ])
      expect(page).to have_css(".ProseMirror strong")
      editor.send_keys([ modifier, "b" ])
      editor.send_keys([ modifier, "i" ])
      expect(page).to have_css(".ProseMirror em")
      editor.send_keys([ modifier, "i" ])
    end
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, :shift, "8" ])
    expect(page).to have_css(".ProseMirror ul li")
    selection_error = page.evaluate_async_script(<<~'JS')
      const done = arguments[0]
      import("prosemirror-state").then(({ TextSelection }) => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor")
        const view = controller.richEditor.view
        view.dispatch(view.state.tr.setSelection(TextSelection.atEnd(view.state.doc)))
        view.focus()
        done()
      }).catch(error => done(error.message))
    JS
    expect(selection_error).to be_nil
    editor.send_keys(:enter)
    expect(page).to have_css(".ProseMirror li", count: 2)
    editor.send_keys("Second item")
    expect(page).to have_css(".ProseMirror li", count: 2)
  end

  it "incorporates agent changes while preserving local undo and selection" do
    visit plan_edit_page_path(plan)
    editor
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      import("coplan/rich_document").then(m => {
        const host = document.createElement("div");
        const rich = m.createRichDocument(host, "Alpha paragraph.\n\nBeta paragraph.\n", () => {});
        rich.view.dispatch(rich.view.state.tr.insertText("HUMAN ", 1));
        const selection = rich.view.state.selection.from;
        rich.update("HUMAN Alpha paragraph.\n\nAGENT Beta paragraph.\n");
        const after = rich.content(), selected = rich.view.state.selection.from;
        rich.command("undo"); const undone = rich.content();
        rich.command("redo"); const redone = rich.content();
        rich.update(redone.replace("Beta", "**Beta**"));
        const formatted = rich.content();
        rich.destroy(); done({ after, selection, selected, undone, redone, formatted });
      }).catch(e => done({ error: e.stack }));
    JS
    expect(result["error"]).to be_nil
    expect(result["selected"]).to eq(result["selection"])
    expect(result["after"]).to include("HUMAN Alpha", "AGENT Beta")
    expect(result["undone"]).to include("Alpha", "AGENT Beta")
    expect(result["undone"]).not_to include("HUMAN")
    expect(result["redone"]).to include("HUMAN Alpha", "AGENT Beta")
    expect(result["formatted"]).to include("AGENT **Beta**")
  end

  it "keeps source-only and unsupported remote edits and undo within a formatted paragraph" do
    visit plan_edit_page_path(plan)
    editor
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      import("coplan/rich_document").then(m => {
        const rich = m.createRichDocument(document.createElement("div"), "Alpha and beta.", () => {});
        rich.view.dispatch(rich.view.state.tr.insertText("HUMAN ", 1));
        rich.update("HUMAN Alpha and **beta**.");
        rich.command("undo"); const undone = rich.content();
        rich.command("redo"); const redone = rich.content();
        rich.update("HUMAN Alpha and __beta__."); const spelling = rich.content();
        rich.update("| A | B |\n|---|---|\n| 1 | 2 |\n");
        rich.update("| A | B |\n|---|---|\n| 1 | 3 |\n"); const table = rich.content();
        rich.destroy(); done({undone, redone, spelling, table});
      }).catch(e => done({error:e.stack}));
    JS
    expect(result["error"]).to be_nil
    expect(result["undone"]).to eq("Alpha and **beta**.")
    expect(result["redone"]).to eq("HUMAN Alpha and **beta**.")
    expect(result["spelling"]).to eq("HUMAN Alpha and __beta__.")
    expect(result["table"]).to include("| 1 | 3 |")
  end

  it "preserves typing during a delayed save and then saves the newer draft" do
    visit plan_edit_page_path(plan)
    editor
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.fetch = async (url, options) => {
        const response = await original(url, options);
        if (options?.method === "PATCH") { window.saveStarted = true; await new Promise(resolve => setTimeout(resolve, 1800)); }
        return response;
      };
    JS
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "First edit")
    save_now
    expect(page).to have_content("Saving…")
    editor.send_keys(:end, " plus in-flight typing")
    expect(page).to have_content("All changes saved · v3", wait: 12)
    expect(plan.reload.current_content).to include("First edit plus in-flight typing")
    page.refresh
    expect(editor).to have_text("First edit plus in-flight typing")
  end

  it "retains the draft across an expired sign-in and refreshes the token on retry" do
    visit plan_edit_page_path(plan)
    editor
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.signedOut = true;
      const meta = document.querySelector('meta[name="csrf-token"]') || document.head.appendChild(document.createElement('meta'));
      meta.name = 'csrf-token'; meta.content = 'expired';
      window.fetch = async (url, options) => {
        if (window.signedOut && (url.includes('editor_state') || options?.method === 'PATCH')) return new Response('{}', {status: 401, headers: {'Content-Type': 'application/json'}});
        if (options?.method === 'PATCH' && options.headers['X-CSRF-Token'] === 'expired') return new Response('Old session token', {status: 422, headers: {'Content-Type': 'text/html'}});
        return original(url, options);
      };
    JS
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Draft after expired sign-in")
    save_now
    expect(page).to have_content("Sign in again · draft retained")
    expect(editor).to have_text("Draft after expired sign-in")
    page.execute_script('window.signedOut = false')
    click_button "Retry sync", enable_aria_label: true
    expect(page).to have_content("All changes saved · v2")
    expect(plan.reload.current_content).to include("Draft after expired sign-in")
  end

  it "reconciles a committed save whose response was lost without making another version" do
    visit plan_edit_page_path(plan)
    editor
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.allowSnapshots = false;
      window.fetch = async (url, options) => {
        if (url.includes("editor_state") && !window.allowSnapshots) throw new TypeError("Disconnected");
        const response = await original(url, options);
        if (options?.method === "PATCH" && !window.lostResponse) {
          window.lostResponse = true;
          throw new TypeError("Connection lost after commit");
        }
        return response;
      };
    JS
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Committed despite lost response")
    save_now
    expect(page).to have_css('.document-editor__close-inline[data-state="error"][aria-label="Retry sync"]')
    expect(plan.reload.current_revision).to eq(2)
    page.execute_script('window.allowSnapshots = true; window.dispatchEvent(new Event("online"))')
    expect(page).not_to have_content("Not saved", wait: 10)
    expect(editor).to have_text("Committed despite lost response")
    expect(plan.reload.current_revision).to eq(2)
  end

  it "merges a live agent update with an unsaved human edit" do
    visit plan_edit_page_path(plan)
    editor
    # Prevent the human patch long enough to receive a real server version.
    page.execute_script('window.originalFetch = window.fetch; window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : window.originalFetch(url, options)')
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, :end ], " Human addition.")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "# Agent heading\n\nFirst draft body.\n", base_revision: 1,
      actor_type: "local_agent", actor_id: author.id)
    expect(editor).to have_text("Agent heading", wait: 10)
    expect(editor).to have_text("Human addition.")
    page.execute_script('window.fetch = window.originalFetch; window.dispatchEvent(new Event("online"))')
    expect(page).to have_content("All changes saved · v3", wait: 10)
    expect(plan.reload.current_content).to include("Agent heading", "Human addition.")
  end

  def open_plan_menu
    find("#plan-toolbar button[aria-label='More actions']").click
    expect(page).to have_css("#plan-menu:popover-open")
  end

  it "changes visibility from the overflow menu in place, no reload" do
    plan.update!(visibility: "draft")
    visit plan_page_path(plan)

    # Private is the rare state — the byline flags it.
    expect(page).to have_css("#plan-header .state-flag", text: "Private")

    open_plan_menu
    within("#plan-menu") { click_button "Share with everyone" }

    # The Turbo Stream re-renders the header in place: the Private flag
    # drops without a navigation, and a toast confirms.
    expect(page).to have_content("Shared with everyone in the org.")
    expect(page).not_to have_css("#plan-header .state-flag", text: "Private")
    expect(plan.reload.visibility).to eq("published")

    # The menu tracks state: it now offers the opposite direction.
    open_plan_menu
    within("#plan-menu") { click_button "Make private" }
    expect(page).to have_content("Private again — hidden from lists and search.")
    expect(page).to have_css("#plan-header .state-flag", text: "Private")
    expect(plan.reload.visibility).to eq("draft")
  end

  it "returns to the library root after archiving an unfiled plan" do
    visit plan_page_path(plan)
    expect(page).to have_css(".plan-location-link--nav", visible: :all)

    open_plan_menu
    within("#plan-menu") { click_button "Archive plan" }

    expect(page).to have_current_path(browse_library_path(handle: author.library.handle))
    expect(page).to have_css(".archive-confirmation", text: "Archived “Editable Plan”")
    expect(page).to have_link("View archived", href: browse_library_path(handle: author.library.handle, filter: "archived"))
    expect(page).not_to have_css(".plan-row[data-plan-id='#{plan.id}']")
    expect(plan.reload.archived?).to be(true)

    within(".archive-confirmation") { click_button "Undo archive" }
    expect(page).to have_current_path(browse_library_path(handle: author.library.handle))
    expect(page).to have_css(".plan-row[data-plan-id='#{plan.id}']")
    expect(plan.reload.archived?).to be(false)

    # The archived document remains reachable directly and can be restored.
    plan.update!(archived_at: Time.current)
    visit plan_page_path(plan)
    expect(page).to have_css(".plan-banner--archived", text: "hidden from lists")
    expect(page).not_to have_css(".plan-location-link", visible: :all)
    open_plan_menu
    expect(page).not_to have_button("Archive plan")
    find("#plan-toolbar button[aria-label='More actions']").click # close menu

    within(".plan-banner--archived") { click_button "Restore" }
    expect(page).not_to have_css(".plan-banner--archived")
    expect(page).to have_css(".plan-location-link--nav", visible: :all)
    expect(plan.reload.archived?).to be(false)
  end

  it "hides owner controls from non-authors" do
    other = create(:coplan_user, email: "viewer@example.com")
    click_button "Menu"
    click_link "Sign out"
    sign_in(other)

    visit plan_page_path(plan)
    expect(page).to have_content("Editable Plan")
    # A reader gets the overflow menu and nothing else. There used to be a
    # Save here that filed the plan onto their own shelf; a plan lives in
    # one place now, so reading one is just reading it.
    within("#plan-toolbar") do
      expect(page).not_to have_link("Edit")
      expect(page).not_to have_button("Save")
    end
    # The reader's overflow menu is History only — no state-changing actions.
    open_plan_menu
    within("#plan-menu") do
      expect(page).to have_link("History")
      expect(page).not_to have_button("Archive plan")
      expect(page).not_to have_button("Make private")
      expect(page).not_to have_button("Share with everyone")
      expect(page).not_to have_button("Move to folder…")
    end
  end
end
