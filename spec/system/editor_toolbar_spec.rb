require "rails_helper"

RSpec.describe "Editor toolbar", type: :system do
  let(:author) { create(:coplan_user, email: "editor-toolbar@example.com") }
  let(:content) { "Original prose.\n" }
  let(:plan) { CoPlan::Plans::Create.call(title: "Toolbar test", content: content, user: author, visibility: "draft", actor_type: "human") }
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css('[aria-label="Document body"]', wait: 20)
    expect(page).to have_css('.document-editor__save-status[data-state="idle"]', visible: :all)
  end

  def raw
    find('[aria-label="Markdown source"]')
  end

  def status
    find(".document-editor__save-status", visible: :all)
  end

  context "after scrolling a long document" do
    let(:content) { (1..60).map { |n| "Paragraph #{n} to format while scrolled." }.join("\n\n") + "\n" }
    let(:long_thread) do
      thread = create(:comment_thread, plan: plan, created_by_user: author,
        anchor_text: "Paragraph 30 to format while scrolled.")
      create(:comment, comment_thread: thread, author_id: author.id,
        body_markdown: (1..25).map { |n| "Discussion paragraph #{n} with detailed review feedback." }.join("\n\n"))
      create(:review_request, plan: plan)
      thread
    end

    before do
      paragraph = find('[aria-label="Document body"] p', text: "Paragraph 30 to format while scrolled.", exact_text: true)
      page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", paragraph)
      bounds = page.evaluate_script(<<~'JS', paragraph)
        (() => { const range = document.createRange(); range.selectNodeContents(arguments[0]);
        const rect = range.getBoundingClientRect(); return { left: rect.left, right: rect.right, y: (rect.top + rect.bottom) / 2 }; })()
      JS
      page.driver.browser.action.move_to_location(bounds["left"].round, bounds["y"].round)
        .click_and_hold.move_to_location(bounds["right"].ceil, bounds["y"].round).release.perform
      expect(page.evaluate_script("window.scrollY")).to be > 500
      expect(page.evaluate_script("window.getSelection().toString()")).to eq("Paragraph 30 to format while scrolled.")
    end

    it "bolds the selected passage using the sticky toolbar" do
      page.driver.browser.action.move_to(find_button("Bold").native).click.perform

      expect(page).to have_css('[aria-label="Document body"] p strong', text: "Paragraph 30 to format while scrolled.")
      expect(page).to have_css('.document-editor__save-status[data-state="saved"]', visible: :all, wait: 10)
      expect(plan.reload.current_content).to include("**Paragraph 30 to format while scrolled.**")
    end

    it "links the selected passage using the sticky toolbar" do
      accept_prompt("Link URL", with: "https://example.com/scrolled") do
        page.driver.browser.action.move_to(find_button("Link").native).click.perform
      end

      expect(page).to have_css('[aria-label="Document body"] a[href="https://example.com/scrolled"]', text: "Paragraph 30 to format while scrolled.")
      expect(page).to have_css('.document-editor__save-status[data-state="saved"]', visible: :all, wait: 10)
      expect(plan.reload.current_content).to include("[Paragraph 30 to format while scrolled.](https://example.com/scrolled)")
    end

    it "keeps the sticky formatting toolbar clickable beside a long discussion" do
      thread = long_thread
      visit plan_edit_page_path(plan)
      mark = find(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']", wait: 20)
      mark.click
      expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open")
      expect(page.evaluate_script("window.scrollY")).to be > 500

      %w[light dark].each do |theme|
        page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
        page.save_screenshot(Rails.root.join("tmp/editor-long-discussion-#{theme}.png"))
      end
      # A native pointer click must reach the visible toolbar, rather than
      # the discussion's top layer. Do not bypass hit testing with JS click().
      dismiss_prompt("Link URL") do
        page.driver.browser.action.move_to(find_button("Link").native).click.perform
      end
    end

    [ :open, :dismissed ].each do |discussion_state|
      it "keeps the sticky header Edit link clickable after linking to a #{discussion_state} long discussion" do
        thread = long_thread
        plan.update!(title: "A long document title with assigned reviewers and a detailed discussion")
        visit plan_page_path(plan, thread: thread.id)
        expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open")
        if discussion_state == :dismissed
          page.driver.browser.action.send_keys(:escape).perform
          expect(page).to have_no_css("#comment_thread_#{thread.id}_popover:popover-open")
          page.execute_script("window.scrollBy(0, 200)")
        end
        edit = find(".site-nav__plan-context--visible .site-nav__edit")
        # Wait for the title's entrance animation before aiming the mouse.
        expect(page).to have_css(".site-nav__plan-context--visible") do |context|
          context.evaluate_script("getComputedStyle(this).opacity === '1' && this.getAnimations().length === 0")
        end
        bounds = edit.evaluate_script("this.getBoundingClientRect().toJSON()")
        expect(edit.evaluate_script("(() => { const r = this.getBoundingClientRect(); return this.contains(document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)); })()")).to eq(true)
        page.driver.browser.action.move_to_location((bounds["left"] + bounds["width"] / 2).round,
          (bounds["top"] + bounds["height"] / 2).round).click.perform

        expect(page).to have_css('.inline-editor [aria-label="Document body"]', wait: 20)
        expect(page.evaluate_script("window.scrollY")).to be > 500
        dismiss_prompt("Link URL") do
          page.driver.browser.action.move_to(find_button("Link").native).click.perform
        end
      end
    end

    it "bolds selected text while its long discussion is open" do
      thread = long_thread
      visit plan_edit_page_path(plan)
      mark = find(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']", wait: 20)
      mark.click
      expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open")
      page.execute_script(<<~'JS', mark)
        const range = document.createRange(); range.selectNodeContents(arguments[0]);
        const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      JS
      selected = page.evaluate_script("window.getSelection().toString()")
      expect(selected).not_to be_empty

      page.driver.browser.action.move_to(find_button("Bold").native).click.perform

      expect(page).to have_css('[aria-label="Document body"] p strong', text: selected)
      expect(page).to have_css('.document-editor__save-status[data-state="saved"]', visible: :all, wait: 10)
      expect(plan.reload.current_content).to include("**#{selected}**")
    end

    [ :reader, :editor ].each do |surface|
      %w[j k].each do |key|
        it "keeps pinned controls clear after keyboard #{key} navigation in the #{surface}" do
          thread = long_thread
          # Turbo reconnects already-loaded controllers in document order.
          page.execute_script("Turbo.visit(arguments[0])", plan_page_path(plan))
          expect(page).to have_no_css('[aria-label="Document body"]')
          expect(page).to have_css("mark[data-thread-id='comment_thread_#{thread.id}']", wait: 20)
          if surface == :editor
            find("#plan-toolbar a[title='Edit this document']").click
            expect(page).to have_css('[aria-label="Document body"]', wait: 20)
          end
          find("body").send_keys(key)
          popover = "#comment_thread_#{thread.id}_popover"
          expect(page).to have_css("#{popover}:popover-open")
          # The first scroll can also resize the newly opened window. Scroll
          # again after observers settle to exercise later position updates.
          2.times do
            page.execute_script("window.scrollBy(0, 250)")
            page.driver.browser.execute_async_script("requestAnimationFrame(() => requestAnimationFrame(arguments[0]))")
          end
          panel = find(popover)
          expect(panel.evaluate_script(<<~'JS')).to eq(true)
            (() => {
              const controls = [document.querySelector('.site-nav'), ...document.querySelectorAll('.document-editor__toolbar')]
                .filter(element => element?.getClientRects().length && getComputedStyle(element).visibility !== 'hidden');
              return controls.every(element => this.getBoundingClientRect().top >= element.getBoundingClientRect().bottom + 8);
            })()
          JS
          %w[light dark].each do |theme|
            page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
            page.save_screenshot(Rails.root.join("tmp/comment-keyboard-#{surface}-#{key}-#{theme}.png"))
          end
          if surface == :editor
            dismiss_prompt("Link URL") { page.driver.browser.action.move_to(find_button("Link").native).click.perform }
          else
            edit = find(".site-nav__plan-context--visible .site-nav__edit")
            expect(edit.evaluate_script("(() => { const r = this.getBoundingClientRect(); return this.contains(document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)); })()")).to eq(true)
          end
        end
      end
    end

    [ :escape, :outside_click ].each do |dismissal|
      it "keeps a dismissed discussion out of toolbar hit testing after #{dismissal}" do
        thread = long_thread
        visit plan_edit_page_path(plan)
        mark = find(".inline-editor mark[data-thread-id='comment_thread_#{thread.id}']", wait: 20)
        mark.click
        popover = "#comment_thread_#{thread.id}_popover"
        expect(page).to have_css("#{popover}:popover-open")
        if dismissal == :escape
          # Dismiss from the discussion; ProseMirror consumes Escape while
          # its document selection has focus.
          find("#{popover} textarea").click
          page.driver.browser.action.send_keys(:escape).perform
        else
          page.driver.browser.action.move_to_location(1200, 600).click.perform
        end
        expect(page).to have_no_css("#{popover}:popover-open")
        page.execute_script("window.scrollBy(0, 200)")

        expect(page.evaluate_script(<<~'JS', popover)).to eq({ "open" => false, "display" => "none", "area" => 0, "hits" => [ "bold", "link" ] })
          (() => {
            const panel = document.querySelector(arguments[0]), rect = panel.getBoundingClientRect();
            const hits = ['bold', 'link'].map(command => {
              const button = document.querySelector(`[data-command="${command}"]`), bounds = button.getBoundingClientRect();
              return document.elementFromPoint(bounds.left + bounds.width / 2, bounds.top + bounds.height / 2)?.closest('button')?.dataset.command;
            });
            return { open: panel.matches(':popover-open'), display: getComputedStyle(panel).display, area: rect.width * rect.height, hits };
          })()
        JS
        paragraph = find('[aria-label="Document body"] p', text: "Paragraph 30 to format while scrolled.", exact_text: true)
        page.execute_script(<<~'JS', paragraph)
          const range = document.createRange(); range.selectNodeContents(arguments[0]);
          const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        JS
        page.driver.browser.action.move_to(find_button("Bold").native).click.perform
        expect(page).to have_css('[aria-label="Document body"] strong', text: "Paragraph 30 to format while scrolled.")
        dismiss_prompt("Link URL") { page.driver.browser.action.move_to(find_button("Link").native).click.perform }
      end
    end
  end

  it "shows saving through in-flight typing, then fades the acknowledged autosave without moving the toolbar" do
    click_button "Raw", exact: true
    bounds = find(".document-editor__close-inline").rect
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.savedBodies = [];
      window.saveStates = [];
      const status = document.querySelector('.document-editor__save-status');
      new MutationObserver(() => window.saveStates.push({
        state: status.dataset.state, title: status.title,
        queuedVisible: getComputedStyle(status.querySelector('.document-editor__save-queued')).display !== 'none'
      })).observe(status, { attributes: true, attributeFilter: ['data-state'] });
      const firstSave = new Promise(resolve => { window.finishSave = resolve; });
      window.fetch = async (url, options) => {
        if (options?.method !== "PATCH") return original(url, options);
        window.savedBodies.push(JSON.parse(options.body));
        const response = await original(url, options);
        if (window.savedBodies.length === 1) await firstSave;
        return response;
      };
    JS
    raw.send_keys([ mod, "a" ], "First edit")
    expect(page).to have_css('.document-editor__save-status[data-state="saving"] .document-editor__save-spinner')
    expect(status["title"]).to eq("Saving…")
    expect(page.evaluate_script("window.saveStates")).to include(
      { "state" => "queued", "title" => "Changes ready to save", "queuedVisible" => false },
      { "state" => "saving", "title" => "Saving…", "queuedVisible" => false }
    )
    raw.send_keys(:right, " and newer typing")
    expect(status["data-state"]).to eq("saving")
    page.execute_script("window.finishSave()")
    expect(page).to have_css('.document-editor__save-status[data-state="saved"]', visible: :all, wait: 10)
    expect(plan.reload.current_content).to eq("First edit and newer typing")
    expect(status["title"]).to include("All changes saved · v3")
    expect(page).to have_css('#coplan-inline-save-announcement[aria-live="polite"][aria-atomic="true"]', visible: :all)
    expect(find(".document-editor__close-inline").rect).to eq(bounds)
    expect(page.evaluate_script("window.savedBodies.every(body => !('change_summary' in body))")).to eq(true)
    expect(find(".document-editor__close-inline")["data-state"]).to eq("idle")
    raw.send_keys(:right, " again")
    expect(page).to have_css('.document-editor__save-status[data-state="saved"][title*="v4"]', visible: :all, wait: 10)
    expect(find(".document-editor__close-inline")["data-state"]).to eq("idle")
    expect(plan.reload.current_content).to end_with("again")
    page.save_screenshot(Rails.root.join("tmp/editor-toolbar-raw.png"))
  end

  it "clears the queued icon when undo returns to the saved draft before autosave" do
    click_button "Raw", exact: true
    # Both native key sequences occur within the debounce, without a test sleep.
    raw.send_keys([ mod, "a" ], "Temporary edit", [ mod, "z" ])
    expect(raw).to have_text("Original prose.")
    expect(page).to have_css('.document-editor__save-status[data-state="idle"]', visible: :all)
    expect(page).not_to have_css(".document-editor__save-queued")
    expect(plan.reload.current_revision).to eq(1)
  end

  it "keeps save errors visible while typing and recovers after retry" do
    click_button "Raw", exact: true
    page.execute_script('window.originalFetch = window.fetch; window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : window.originalFetch(url, options)')
    raw.send_keys([ mod, "a" ], "Retained draft")
    expect(page).to have_css('.document-editor__close-inline[data-state="error"][aria-label="Retry sync"]')
    raw.send_keys(:right, " with more")
    expect(status["data-state"]).to eq("error")
    expect(plan.reload.current_revision).to eq(1)
    page.execute_script("window.fetch = window.originalFetch")
    find('.document-editor__close-inline[data-state="error"]').click
    expect(page).to have_css('.document-editor__save-status[data-state="saved"]', visible: :all, wait: 10)
    expect(plan.reload.current_content).to eq("Retained draft with more")
  end

  it "keeps formatting visible but disabled for raw focus and restores it for rich focus" do
    click_button "Dual", exact: true
    raw.click
    expect(page).to have_css('[role="toolbar"]')
    expect(page).to have_css('select[aria-label="Paragraph style"]:disabled')
    expect(page).to have_button("Bold", disabled: true)
    expect(page).to have_button("Insert code block", disabled: true)
    raw.send_keys([ mod, "a" ], "Raw changes")
    expect(page).to have_button("Undo", disabled: false)
    click_button "Undo"
    expect(raw).to have_text("Original prose.")
    expect(page).to have_button("Bold", disabled: true)
    click_button "Redo"
    expect(raw).to have_text("Raw changes")
    find('[aria-label="Document body"]').click
    expect(page).to have_css('select[aria-label="Paragraph style"]:enabled')
    expect(page).to have_button("Bold", disabled: false)
    expect(page).to have_button("Insert code block", disabled: false)
    find('[aria-label="Document body"]').send_keys([ mod, "a" ])
    click_button "Bold"
    expect(raw).to have_text("**Raw changes**")
    click_button "Raw", exact: true
    expect(page).to have_css('[role="toolbar"]')
    expect(page).to have_button("Bold", disabled: true)
    expect(raw).to have_text("**Raw changes**")
    click_button "Editor", exact: true
    expect(page).to have_button("Bold", disabled: false)
  end

  it "does not show an autosave check for incoming edits and retains their tags on the next save" do
    plan.update!(tag_names: [ "remote-tag" ])
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Incoming prose.", base_revision: 1, actor_type: "local_agent", actor_id: author.id)
    expect(page).to have_css('[aria-label="Document body"]', text: "Incoming prose.", wait: 10)
    expect(status["data-state"]).to eq("idle")
    expect(page).not_to have_css(".document-editor__save-check")
    click_button "Raw", exact: true
    raw.send_keys([ mod, "a" ], "Human follow-up")
    expect(page).to have_css('.document-editor__save-status[data-state="saved"]', visible: :all, wait: 10)
    expect(plan.reload.current_content).to eq("Human follow-up")
    expect(plan.tag_names).to eq([ "remote-tag" ])
  end

  it "keeps the save indicator at the right edge when controls wrap on a narrow screen" do
    original_size = page.current_window.size
    page.current_window.resize_to(390, 844)
    bounds = page.evaluate_script(<<~'JS')
      (() => {
        const toolbar = document.querySelector('.document-editor__toolbar').getBoundingClientRect();
        const status = document.querySelector('.document-editor__close-inline').getBoundingClientRect();
        return { gap: toolbar.right - status.right, top: status.top - toolbar.top, right: toolbar.right, width: innerWidth };
      })()
    JS
    expect(bounds["gap"]).to be_between(0, 15)
    expect(bounds["top"]).to be_between(0, 15)
    expect(bounds["right"]).to be <= bounds["width"]
    page.save_screenshot(Rails.root.join("tmp/editor-toolbar-mobile.png"))
  ensure
    page.current_window.resize_to(*original_size) if original_size
  end
end
