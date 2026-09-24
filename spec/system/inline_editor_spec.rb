require "rails_helper"

RSpec.describe "Inline plan editing", type: :system do
  let(:author) { create(:coplan_user, email: "inline-editor@example.com") }
  let(:content) { "# A plan\n\nFirst paragraph.\n\nSecond paragraph.\n" }
  let(:plan) do
    CoPlan::Plans::Create.call(title: "Inline plan", content: content, user: author,
      visibility: "draft", actor_type: "human")
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_page_path(plan)
  end

  it "edits and saves the document without navigating away" do
    original_path = current_path
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    expect(page).to have_current_path(original_path)
    expect(page).to have_css("[data-coplan--inline-editor-target='reader'][hidden]", visible: :all)
    expect(page).to have_css(".inline-editor button.document-editor__close-inline > .document-editor__save-status", count: 1, visible: :all)
    expect(page).to have_css("#coplan-inline-save-announcement[role='status'][aria-live='polite']", visible: :all)
    close_width = find(".inline-editor button.document-editor__close-inline").rect.width

    find(".inline-editor .ProseMirror p", text: "Second paragraph.").click
    page.driver.browser.action.send_keys(" Added inline.").perform
    expect(page).to have_css(".inline-editor .ProseMirror", text: "Added inline.")
    expect(page).to have_css(".document-editor__save-status[data-state='saved']", visible: :all, wait: 15)
    expect(find(".inline-editor button.document-editor__close-inline")["title"]).to include("All changes saved")
    expect(find(".inline-editor button.document-editor__close-inline").rect.width).to eq(close_width)
    find(".inline-editor").click_button "Done editing"

    expect(page).to have_css("#plan-content-body", text: "Added inline.", wait: 15)
    expect(page).to have_current_path(original_path)
    expect(plan.reload.current_content).to include("Added inline.")
    expect(page).to have_no_css(".inline-editor form.document-editor", wait: 10)
  end

  it "keeps the page at the top when editing starts above the document" do
    page.execute_script("window.scrollTo(0, 0)")
    expect(page.evaluate_script("window.scrollY")).to eq(0)
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    expect(page.evaluate_script("window.scrollY")).to be <= 2
    expect(page).to have_css("#plan-header .inline-editor__title", visible: true)
    find(".inline-editor").click_button "Done editing"
    expect(page).to have_no_css(".inline-editor form.document-editor", wait: 10)
    expect(page.evaluate_script("window.scrollY")).to be <= 2
  end

  it "shows one icon at a time and prevents closing during a save" do
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    page.execute_script(<<~JS)
      const originalFetch = window.fetch
      const release = new Promise(resolve => { window.finishInlineSave = resolve })
      window.fetch = async (url, options) => {
        const response = await originalFetch(url, options)
        if (options?.method === 'PATCH') await release
        return response
      }
    JS

    find(".inline-editor .ProseMirror p", text: "Second paragraph.").click
    page.driver.browser.action.send_keys(" Saved before closing.").perform
    expect(page).to have_css(".inline-editor button.document-editor__close-inline .document-editor__save-status[data-state='saving']", wait: 10)
    expect(page).to have_css(".inline-editor button.document-editor__close-inline[disabled][aria-label='Saving document']")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.inline-editor .document-editor__close-icon')).display")).to eq("none")
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']")
    page.execute_script("window.finishInlineSave()")
    expect(page).to have_css(".inline-editor button.document-editor__close-inline[data-state='idle']:not([disabled])[aria-label='Done editing'] .document-editor__save-status[data-state='saved']", visible: :all, wait: 15)
    expect(page.evaluate_script(<<~JS)).to eq(true)
      (() => {
        const button = document.querySelector('.inline-editor .document-editor__close-inline')
        const check = button.querySelector('.document-editor__close-icon')
        return getComputedStyle(check).display !== 'none' &&
          Number(check.getAttribute('width')) >= 22 &&
          check.querySelector('path').getAttribute('d') === 'm4.5 12 5 5 10-10'
      })()
    JS
    find(".inline-editor").click_button "Done editing"
    expect(page).to have_no_css(".inline-editor form.document-editor", wait: 15)
    expect(page).to have_css("#plan-content-body", text: "Saved before closing.")
  end

  it "saves a queued edit when Done is clicked before autosave starts" do
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    page.execute_script(<<~JS)
      const originalFetch = window.fetch
      const release = new Promise(resolve => { window.finishQueuedSave = resolve })
      window.fetch = async (url, options) => {
        const response = await originalFetch(url, options)
        if (options?.method === 'PATCH') await release
        return response
      }
      const form = document.querySelector('.inline-editor form.document-editor')
      const view = window.Stimulus.getControllerForElementAndIdentifier(form, 'coplan--editor').richEditor.view
      view.dispatch(view.state.tr.insertText(' New text.', view.state.doc.content.size - 1))
      const close = form.querySelector('.document-editor__close-inline')
      window.queuedCloseState = close.dataset.state
      window.queuedCloseLabel = close.getAttribute('aria-label')
      window.queuedSpinnerDuration = getComputedStyle(close.querySelector('.document-editor__save-spinner')).animationDuration
      window.queuedCloseIconVisible = getComputedStyle(close.querySelector('.document-editor__close-icon')).display !== 'none'
      close.click()
    JS
    expect(page.evaluate_script("window.queuedCloseState")).to eq("queued")
    expect(page.evaluate_script("window.queuedCloseLabel")).to eq("Done editing and save changes")
    expect(page.evaluate_script("window.queuedCloseIconVisible")).to eq(false)
    expect(page).to have_css(".inline-editor button.document-editor__close-inline[data-state='saving'][disabled]", wait: 10)
    unless page.evaluate_script("matchMedia('(prefers-reduced-motion: reduce)').matches")
      expect(page.evaluate_script("parseFloat(window.queuedSpinnerDuration) > parseFloat(getComputedStyle(document.querySelector('.inline-editor .document-editor__save-spinner')).animationDuration)")).to eq(true)
    end
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']")
    page.execute_script("window.finishQueuedSave()")
    expect(page).to have_no_css(".inline-editor form.document-editor", wait: 15)
    expect(plan.reload.current_content).to include("New text.")
  end

  it "keeps the caret on the same Markdown characters across inline mode switches" do
    markdown = "# A plan\n\nFirst paragraph.\n\nSecond **paragraph**.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: markdown,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_page_path(plan)
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    page.execute_script(<<~JS)
      const node = document.querySelector('.inline-editor .ProseMirror strong').firstChild
      const range = document.createRange()
      range.setStart(node, 4)
      range.collapse(true)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
    JS

    click_button "Switch to Markdown"
    expect(page.evaluate_script("window.getSelection().anchorOffset")).to eq(markdown.index("paragraph**") + 4)
    click_button "Switch to editor"
    expect(page.evaluate_script("window.getSelection().anchorNode.textContent")).to eq("paragraph")
    expect(page.evaluate_script("window.getSelection().anchorOffset")).to eq(4)

    click_button "Switch to Markdown"
    page.execute_script(<<~JS, markdown.index("First paragraph") + 6)
      const node = document.querySelector('.inline-editor .document-editor__raw .ProseMirror code').firstChild
      const range = document.createRange()
      range.setStart(node, arguments[0])
      range.collapse(true)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
    JS
    click_button "Switch to editor"
    expect(page.evaluate_script("window.getSelection().anchorNode.textContent")).to eq("First paragraph.")
    expect(page.evaluate_script("window.getSelection().anchorOffset")).to eq(6)
  end

  it "edits the title in place" do
    visit "#{plan_page_path(plan)}?from=review#context"
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    title = find("#plan-header .inline-editor__title", wait: 10)
    title.click
    title.send_keys([RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a"])
    title.send_keys("A clearer title")
    find(".inline-editor").click_button "Done editing"

    expect(page).to have_css("#plan-content-body", text: "Second paragraph.", wait: 10)
    expect(plan.reload.title).to eq("A clearer title")
    expect(URI(page.current_url).path).to eq(plan_page_path(plan))
    expect(page.current_url).to end_with("?from=review#context")
  end

  it "wraps long titles and offers hidden formatting controls without a visible scrollbar" do
    plan.update!(title: "A long working title about collaborative planning and rich editing that needs to stay fully visible while someone changes it")
    visit plan_page_path(plan)
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)

    page.execute_script("document.querySelector('.inline-editor__title').style.maxWidth = '320px'")
    expect(page.evaluate_script("document.querySelector('.inline-editor__title').getBoundingClientRect().height > parseFloat(getComputedStyle(document.querySelector('.inline-editor__title')).lineHeight) * 1.5")).to eq(true)
    expect(page.evaluate_script("document.querySelector('.inline-editor__title').scrollWidth <= document.querySelector('.inline-editor__title').clientWidth")).to eq(true)
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.document-editor__format-controls')).scrollbarWidth")).to eq("none")
    page.execute_script("document.querySelector('.document-editor__format-controls').style.maxWidth = '360px'")
    expect(page).to have_css(".document-editor__more-tools", visible: true)
    find(".document-editor__more-tools").click
    expect(page).to have_css('.document-editor__more-tools[aria-label="Earlier formatting tools"]', wait: 5)
  end

  it "keeps the visible title within the saved title limit" do
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor__title", wait: 20)
    title = find(".inline-editor__title")
    title.click
    title.send_keys([RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a"])
    title.send_keys("A" * 280)

    expect(title.text.length).to eq(255)
    find(".inline-editor").click_button "Done editing"
    expect(page).to have_no_css(".inline-editor form.document-editor", wait: 10)
    expect(plan.reload.title.length).to eq(255)
  end

  it "keeps the visible passage fixed when editing starts and ends halfway down a long plan" do
    long_content = (1..80).map { |n| "Paragraph #{n} has enough words to show its position in the document." }.join("\n\n")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: long_content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_page_path(plan)
    page.execute_script("document.querySelectorAll('#plan-content-body p')[40].scrollIntoView({block: 'start'})")
    expect(page).to have_css(".site-nav__edit", visible: true)
    before = page.evaluate_script("document.querySelectorAll('#plan-content-body p')[40].getBoundingClientRect().top")

    find(".site-nav__edit").click
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    expect(page).to have_current_path(plan_page_path(plan))
    during = page.evaluate_script("Array.from(document.querySelectorAll('.inline-editor .ProseMirror p')).find(p => p.textContent.startsWith('Paragraph 41'))?.getBoundingClientRect().top")
    expect(during).to be_within(24).of(before)

    find(".inline-editor").click_button "Done editing"
    expect(page).to have_no_css(".inline-editor form.document-editor", wait: 10)
    after = page.evaluate_script("document.querySelectorAll('#plan-content-body p')[40].getBoundingClientRect().top")
    expect(after).to be_within(24).of(before)
  end

  it "navigates the outline within the editing surface" do
    sections = "# First\n\n" + (1..35).map { |n| "First section paragraph #{n}." }.join("\n\n") +
      "\n\n# Second\n\nSecond section text."
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: sections,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_page_path(plan)
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    within(".content-nav") { click_link "Second" }

    Selenium::WebDriver::Wait.new(timeout: 5).until do
      top = page.evaluate_script("Array.from(document.querySelectorAll('.inline-editor .ProseMirror h1')).find(h => h.textContent.includes('Second')).getBoundingClientRect().top")
      top.between?(0, page.evaluate_script("window.innerHeight"))
    end
    find(".inline-editor .ProseMirror h1", text: "Second").click
    page.driver.browser.action.send_keys(:end, " updated").perform
    expect(page).to have_link("Second updated", wait: 5)
    expect(page).to have_current_path(plan_page_path(plan))
  end

  it "updates the editing outline when an agent changes a heading" do
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    expect(page).to have_css(".content-nav", text: "A plan")

    CoPlan::Plans::ReplaceContent.call(plan: plan.reload,
      new_content: content.sub("# A plan", "# Revised plan"),
      base_revision: plan.current_revision, actor_type: "local_agent", actor_id: author.id)

    expect(page).to have_css(".inline-editor .ProseMirror h1", text: "Revised plan", wait: 10)
    expect(page).to have_css(".content-nav__link", text: "Revised plan", wait: 10)
    expect(page).to have_current_path(plan_page_path(plan))
  end

  it "keeps a comment highlight and thread popover usable while editing" do
    thread = create(:comment_thread, plan: plan, created_by_user: author,
      anchor_text: "Second paragraph.")
    thread.comments.create!(author_type: "human", author_id: author.id,
      body_markdown: "Please clarify this sentence")
    visit plan_page_path(plan)
    within("#plan-toolbar") { click_link "Edit" }

    find(".inline-editor .ProseMirror p", text: "First paragraph.").click
    page.driver.browser.action.send_keys(:end, " More context.").perform
    mark = find(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']", wait: 20)
    expect(mark).to have_text("Second paragraph.")
    mark.click
    expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open",
      text: "Please clarify this sentence")
    expect(page).to have_current_path(plan_page_path(plan))
  end

  it "keeps a comment pinned when one letter inside its quote changes" do
    thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Second paragraph.")
    thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Keep this note")
    visit plan_page_path(plan)
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    find(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']").click
    expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open")
    page.execute_script(<<~JS)
      const form = document.querySelector('.inline-editor form.document-editor')
      const view = window.Stimulus.getControllerForElementAndIdentifier(form, 'coplan--editor').richEditor.view
      let position
      view.state.doc.descendants((node, pos) => {
        if (node.isText && node.text.includes('Second paragraph.')) position = pos + node.text.indexOf('paragraph') + 1
      })
      view.dispatch(view.state.tr.insertText('x', position, position + 1))
    JS
    expect(page).to have_css(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']", text: "Second pxragraph.", wait: 2)
    expect(page).to have_css(".document-editor__save-status[data-state='saved']", visible: :all, wait: 15)
    expect(thread.reload).not_to be_out_of_date
    expect(thread.anchor_text).to eq("Second pxragraph.")
    expect(page).to have_css(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']", text: "Second pxragraph.", wait: 5)
    expect(page).to have_css("#comment_thread_#{thread.id}[data-anchor-text='Second pxragraph.']", visible: :all, wait: 5)
    find(".inline-editor").click_button "Done editing"
    expect(page).to have_css("#plan-content-body mark[data-thread-id='comment_thread_#{thread.id}']", text: "Second pxragraph.", wait: 15)
  end

  it "keeps a quote highlighted when more than eight characters are inserted inside it" do
    thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Second paragraph.")
    thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Keep this note")
    visit plan_page_path(plan)
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']", wait: 10)

    page.execute_script(<<~JS)
      const form = document.querySelector('.inline-editor form.document-editor')
      const view = window.Stimulus.getControllerForElementAndIdentifier(form, 'coplan--editor').richEditor.view
      let position
      view.state.doc.descendants((node, pos) => {
        if (node.isText && node.text.includes('Second paragraph.')) position = pos + node.text.indexOf('paragraph')
      })
      view.dispatch(view.state.tr.insertText('asdfdsaasdf', position))
    JS

    expected_text = "Second asdfdsaasdfparagraph."
    expect(page).to have_css(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']", text: expected_text, wait: 2)
    expect(page).to have_css(".document-editor__save-status[data-state='saved']", visible: :all, wait: 15)
    expect(thread.reload).not_to be_out_of_date
    expect(thread.anchor_text).to eq(expected_text)

    page.execute_script(<<~JS)
      const form = document.querySelector('.inline-editor form.document-editor')
      const view = window.Stimulus.getControllerForElementAndIdentifier(form, 'coplan--editor').richEditor.view
      let position
      view.state.doc.descendants((node, pos) => {
        if (node.isText && node.text.includes('asdfdsaasdf')) position = pos + node.text.indexOf('asdfdsaasdf')
      })
      view.dispatch(view.state.tr.delete(position, position + 11))
    JS
    expect(page).to have_css(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']", text: "Second paragraph.", wait: 2)
    expect(page).to have_css(".document-editor__save-status[data-state='saved']", visible: :all, wait: 15)
    expect(thread.reload).not_to be_out_of_date
    expect(thread.anchor_text).to eq("Second paragraph.")
    find(".inline-editor").click_button "Done editing"
    expect(page).to have_css("#plan-content-body mark[data-thread-id='comment_thread_#{thread.id}']", text: "Second paragraph.", wait: 15)
  end

  it "shows an out-of-date comment without moving it to another matching passage" do
    thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Second paragraph.")
    thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Original placement")
    thread.update_columns(out_of_date: true)
    visit plan_page_path(plan)

    expect(page).to have_no_css("#plan-content-body mark[data-thread-id='comment_thread_#{thread.id}']")
    within("#plan-detached-comments") { click_button "Second paragraph." }
    expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open", text: "Original placement")
  end

  it "uses the visible editing surface for voice comment context" do
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    expect(page.evaluate_script("window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('.voice-control'), 'coplan--voice')._contentRoot().classList[0]")).to eq("ProseMirror")
  end

  it "keeps comments on table cells and Mermaid labels in their previews" do
    mixed = "# Mixed content\n\n| Name | State |\n| --- | --- |\n| Alpha | Ready |\n\n```mermaid\ngraph LR\n  A[Start] --> B[Finish]\n```\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: mixed,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    table_thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Ready")
    table_thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Check state")
    diagram_thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Finish")
    diagram_thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Check destination")
    visit plan_page_path(plan)
    within("#plan-toolbar") { click_link "Edit" }

    table_mark = find(".inline-editor .document-editor__block-preview table mark[data-thread-id='comment_thread_#{table_thread.id}']", wait: 20)
    expect(table_mark).to have_text("Ready")
    expect(page).to have_css(".inline-editor .document-editor__block-preview .mermaid-diagram svg", wait: 20)
    diagram_mark = find(".inline-editor .document-editor__block-preview .mermaid-diagram mark[data-thread-id='comment_thread_#{diagram_thread.id}']", wait: 20)
    expect(diagram_mark).to have_text("Finish")
    table_mark.click
    expect(page).to have_css("#comment_thread_#{table_thread.id}_popover:popover-open", text: "Check state")
  end

  it "anchors a new comment to selected text while editing" do
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    page.execute_script(<<~JS)
      const paragraph = Array.from(document.querySelectorAll('.inline-editor .ProseMirror p'))
        .find(p => p.textContent === 'Second paragraph.')
      const range = document.createRange()
      range.selectNodeContents(paragraph)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
      paragraph.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }))
    JS
    expect(page).to have_css(".comment-popover", visible: true)
    find(".comment-popover button", text: "Comment").click
    expect(page).to have_css("#new-comment-form", visible: true)
    within("#new-comment-form") do
      fill_in "comment_thread_body_markdown", with: "Please expand this"
      click_button "Comment"
    end
    expect(page).to have_css(".inline-editor mark.anchor-highlight--open", text: "Second paragraph.", wait: 10)
    expect(CoPlan::CommentThread.where(plan: plan, anchor_text: "Second paragraph.").count).to eq(1)
  end

  it "anchors a new comment selected from a table preview" do
    mixed = "# Table\n\n| Name | State |\n| --- | --- |\n| Alpha | Ready |\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: mixed,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_page_path(plan)
    within("#plan-toolbar") { click_link "Edit" }
    find(".inline-editor .document-editor__block-preview table td", text: "Ready", wait: 20)
    page.execute_script(<<~JS)
      const cell = Array.from(document.querySelectorAll('.inline-editor .document-editor__block-preview table td'))
        .find(cell => cell.textContent === 'Ready')
      const range = document.createRange()
      range.selectNodeContents(cell)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
      cell.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }))
    JS
    expect(page).to have_css(".comment-popover", visible: true)
    find(".comment-popover button", text: "Comment").click
    within("#new-comment-form") do
      fill_in "comment_thread_body_markdown", with: "Confirm the state"
      click_button "Comment"
    end
    expect(page).to have_css(".inline-editor .document-editor__block-preview table mark.anchor-highlight--open", text: "Ready", wait: 10)
    expect(CoPlan::CommentThread.where(plan: plan, anchor_text: "Ready").count).to eq(1)
  end

  it "keeps the reading passage in place and pulses the outline for an offscreen agent edit" do
    long_content = "# Introduction\n\nOpening words.\n\n# Main section\n\n" +
      (1..75).map { |n| "Main paragraph #{n} with a stable reading position." }.join("\n\n")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: long_content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    thread = create(:comment_thread, plan: plan, created_by_user: author,
      anchor_text: "Main paragraph 40 with a stable reading position.")
    thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Keep this anchored")
    visit plan_page_path(plan)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all, wait: 10)
    page.execute_script("document.querySelectorAll('#plan-content-body p')[40].scrollIntoView({block: 'start'})")
    before = page.evaluate_script("document.querySelectorAll('#plan-content-body p')[40].getBoundingClientRect().top")

    CoPlan::Plans::ReplaceContent.call(plan: plan.reload,
      new_content: long_content.sub("Opening words.", "Opening words. A remote addition above the reader."),
      base_revision: plan.current_revision, actor_type: "local_agent", actor_id: author.id)

    expect(page).to have_css("#plan-content-body", text: "A remote addition above the reader.", wait: 10)
    after = page.evaluate_script("Array.from(document.querySelectorAll('#plan-content-body p')).find(p => p.textContent.startsWith('Main paragraph 40'))?.getBoundingClientRect().top")
    expect(after).to be_within(24).of(before)
    expect(page).to have_css(".content-nav__item--remote-change[data-heading-id='introduction']")
    expect(page).to have_css("#plan-content-body mark[data-thread-id='comment_thread_#{thread.id}']", text: "Main paragraph 40", wait: 10)
  end
end
