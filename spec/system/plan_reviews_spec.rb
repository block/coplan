require "rails_helper"

RSpec.describe "Plan discussion and approval", type: :system do
  let(:author) { create(:coplan_user, email: "approval-author@example.com", username: "approval-author", name: "Plan Author") }
  let(:reviewer) { create(:coplan_user, email: "approval-reviewer@example.com", username: "approval-reviewer", name: "Plan Reviewer") }
  let(:plan) { create(:plan, :published, created_by_user: author, title: "Review tray playground") }
  let!(:task) { create(:review_request, plan: plan, reviewer: reviewer) }

  def sign_in_browser(user, open_sections: true)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    if user == author
      expect(page).to have_current_path(library_page_path(user), wait: 10)
    else
      expect(page).to have_link("Go to your library", wait: 10)
    end
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-review-controls")
    if open_sections
      expand_plan_section("footnote-approvals")
      expand_plan_section("plan-general-comments")
    end
  end

  def lose_next_review_result
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window);
      let loseResponse = true;
      window.fetch = async (...args) => {
        const result = await originalFetch(...args);
        if (loseResponse && args[1]?.method === "POST" && String(args[0]).endsWith("/respond")) {
          loseResponse = false;
          throw new TypeError("Simulated lost HTTP result after the server saved it");
        }
        return result;
      };
    JS
  end

  before { sign_in_browser(reviewer, open_sections: !RSpec.current_example.metadata[:collapsed_support]) }

  def open_review_settings
    expect(page).to have_no_css("html[aria-busy='true']")
    expand_plan_section("footnote-approvals")
    within("#footnote-approvals") { click_button "Manage reviewers" }
    expect(page).to have_css(".review-management[open]")
  end

  [ "light", "dark" ].each do |theme|
    it "persists the default-on reset policy from the reviewer dialog in #{theme} theme", :review_reset_policy do
      sign_in_browser(author)
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      open_review_settings
      within(".review-management[open]") do
        expect(page).to have_checked_field("Reset approvals when content changes")
        uncheck "Reset approvals when content changes"
        expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
      end
      expect(page).to have_css(".review-reset-policy__status[data-state='saved']")
      expect(plan.reload.reset_reviews_on_change).to be(false)
      visit plan_page_path(plan)
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      open_review_settings
      within(".review-management[open]") do
        expect(page).to have_unchecked_field("Reset approvals when content changes")
        check "Reset approvals when content changes"
        expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
      end
      expect(plan.reload.reset_reviews_on_change).to be(true)
      page.save_screenshot(Rails.root.join("tmp/review-preview/reset-policy-#{theme}.png"))
    end
  end

  it "keeps reviews completed after edits when off, then resets after the next edit when enabled", :review_reset_policy do
    sign_in_browser(author)
    open_review_settings
    within(".review-management[open]") do
      uncheck "Reset approvals when content changes"
      expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
    end
    sign_in_browser(reviewer)
    within(".review-tray") { click_button "Approve", exact: true }
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_css(".review-tray", text: "You approved v1")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "# Second version", base_revision: 1, actor_type: "human", actor_id: author.id)
    visit plan_page_path(plan)
    expand_plan_section("footnote-approvals")
    expect(page).to have_css(".review-tray", text: "You approved v1")
    expect(page).to have_css(".review-tray", text: "no new review required")
    expect(page).to have_css(".review-person", text: "Content changed since review")
    expect(page).to have_no_css(".review-tray", text: "Your review is requested")
    expect(task.reload.effective_human_decision).to be_nil
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/retained-review-#{theme}.png"))
    end
    sign_in_browser(author)
    open_review_settings
    within(".review-management[open]") do
      check "Reset approvals when content changes"
      expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
    end
    expect(task.reload.review_status).to eq("approved")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "# Third version", base_revision: 2, actor_type: "human", actor_id: author.id)
    visit plan_page_path(plan)
    expand_plan_section("footnote-approvals")
    expect(page).to have_css(".review-person__meta", text: "Content changed; review again")
    expect(task.reload).to be_pending
  end

  it "autosaves the latest checkbox choice without save text or blocking more clicks", :review_reset_policy do
    sign_in_browser(author)
    open_review_settings
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window)
      window.policyWrites = []
      window.fetch = async (url, options) => {
        if (options?.method === 'PATCH' && String(url).endsWith('/settings')) {
          window.policyWrites.push(JSON.parse(options.body).review_settings.reset_reviews_on_change)
          document.querySelector("[data-review-reset-policy]").dataset.firstPolicyWrite = "true"
          const result = await originalFetch(url, options)
          await new Promise(resolve => setTimeout(resolve, 400))
          return result
        }
        return originalFetch(url, options)
      }
    JS
    within(".review-management[open]") do
      page.execute_script('const input = document.querySelector("[data-review-reset-policy]"); input.click(); input.click()')
      expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
      expect(page.evaluate_script("window.policyWrites")).to eq([])
      uncheck "Reset approvals when content changes"
      expect(page).to have_css("[data-review-reset-policy][aria-busy='true']")
      expect(page).to have_no_text("Saving…")
      expect(page).to have_no_text("Saved")
      # Wait until the first request is in flight, then change our mind.
      expect(page).to have_selector("[data-review-reset-policy][data-saved-value='true']")
      expect(page).to have_css("[data-review-reset-policy][data-first-policy-write='true']")
      check "Reset approvals when content changes"
      expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
      expect(page).to have_checked_field("Reset approvals when content changes", disabled: false)
    end
    expect(plan.reload.reset_reviews_on_change).to be(true)
    expect(page.evaluate_script("window.policyWrites")).to eq([ false, true ])
  end

  it "reconciles a lost save response with the persisted checkbox value", :review_reset_policy do
    sign_in_browser(author)
    open_review_settings
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window)
      let loseResult = true
      window.fetch = async (url, options) => {
        const result = await originalFetch(url, options)
        if (loseResult && options?.method === 'PATCH' && String(url).endsWith('/settings')) {
          loseResult = false
          throw new TypeError('Lost saved result')
        }
        return result
      }
    JS
    within(".review-management[open]") do
      uncheck "Reset approvals when content changes"
      expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
      expect(page).to have_unchecked_field("Reset approvals when content changes")
    end
    expect(plan.reload.reset_reviews_on_change).to be(false)
    visit plan_page_path(plan)
    open_review_settings
    expect(page).to have_unchecked_field("Reset approvals when content changes")
  end

  it "restores the saved reset preference after a rejected settings update", :review_reset_policy do
    sign_in_browser(author)
    open_review_settings
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window)
      let reject = true
      window.fetch = (url, options) => {
        if (reject && options?.method === 'PATCH' && String(url).endsWith('/settings')) {
          reject = false
          return Promise.resolve(new Response(JSON.stringify({error: 'Unable to save settings'}), {status: 422, headers: {'Content-Type': 'application/json'}}))
        }
        return originalFetch(url, options)
      }
    JS
    within(".review-management[open]") do
      uncheck "Reset approvals when content changes"
      expect(page).to have_text("Unable to save settings")
      expect(page).to have_checked_field("Reset approvals when content changes", disabled: false)
      expect(plan.reload.reset_reviews_on_change).to be(true)
      uncheck "Reset approvals when content changes"
      expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
    end
    expect(plan.reload.reset_reviews_on_change).to be(false)
  end

  it "replays another tab's policy invalidation after a delayed save response", :review_reset_policy do
    sign_in_browser(author)
    open_review_settings
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window)
      window.fetch = async (url, options) => {
        const result = await originalFetch(url, options)
        if (options?.method === 'PATCH' && String(url).endsWith('/settings')) {
          document.querySelector('[data-review-reset-policy]').dataset.committed = 'true'
          await new Promise(resolve => { window.releasePolicy = resolve })
        }
        return result
      }
    JS
    uncheck "Reset approvals when content changes"
    expect(page).to have_css("[data-review-reset-policy][data-committed='true']")
    # Another author tab commits the opposite setting before our response arrives.
    plan.reload.update!(reset_reviews_on_change: true)
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const root = document.getElementById('plan-review-controls')
      window.Stimulus.getControllerForElementAndIdentifier(root, 'coplan--review-tray').refresh().then(done)
    JS
    page.execute_script("window.releasePolicy()")
    expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
    expect(page).to have_checked_field("Reset approvals when content changes")
    expect(plan.reload.reset_reviews_on_change).to be(true)
    expect(page).to have_no_css(".review-reset-policy__status[data-state='saved']")
  end

  it "keeps a newer off choice when the first off request fails", :review_reset_policy do
    sign_in_browser(author)
    open_review_settings
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window)
      window.policyWrites = []
      window.fetch = async (url, options) => {
        if (options?.method === 'PATCH' && String(url).endsWith('/settings')) {
          window.policyWrites.push(JSON.parse(options.body).review_settings.reset_reviews_on_change)
          if (window.policyWrites.length === 1) {
            document.querySelector('[data-review-reset-policy]').dataset.inFlight = 'true'
            return await new Promise(resolve => { window.rejectPolicy = () => resolve(new Response(JSON.stringify({error: 'Rejected'}), {status: 422})) })
          }
        }
        return originalFetch(url, options)
      }
    JS
    uncheck "Reset approvals when content changes"
    expect(page).to have_css("[data-review-reset-policy][data-in-flight='true']")
    page.execute_script(<<~JS)
      const input = document.querySelector('[data-review-reset-policy]')
      input.click(); input.click(); window.rejectPolicy()
    JS
    expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
    expect(page).to have_unchecked_field("Reset approvals when content changes")
    expect(plan.reload.reset_reviews_on_change).to be(false)
    expect(page.evaluate_script("window.policyWrites")).to eq([ false, false ])
  end

  it "retries the selected policy after a concurrent review sequence change", :review_reset_policy do
    sign_in_browser(author)
    open_review_settings
    plan.reload.update!(review_sequence: plan.review_sequence + 1)
    uncheck "Reset approvals when content changes"
    expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
    expect(page).to have_unchecked_field("Reset approvals when content changes")
    expect(plan.reload.reset_reviews_on_change).to be(false)
    expect(page).to have_no_text("Review settings changed. Please try again.")
  end

  [ true, false ].each do |newer_choice|
      it "fences a lost older write with newer input=#{newer_choice}", :review_reset_policy do
      sign_in_browser(author)
      open_review_settings
      page.execute_script(<<~JS, newer_choice)
        const newerChoice = arguments[0]
        const originalTimeout = window.setTimeout.bind(window)
        if (!newerChoice) window.setTimeout = (action, delay, ...args) => originalTimeout(action, delay === 10000 ? 100 : delay, ...args)
        const originalFetch = window.fetch.bind(window)
        let first = true
        window.fetch = async (url, options) => {
          if (first && options?.method === 'PATCH' && String(url).endsWith('/settings')) {
            first = false
            document.querySelector('[data-review-reset-policy]').dataset.inFlight = 'true'
            window.deliverOldPolicy = async () => {
              const result = await originalFetch(url, {...options, signal: undefined})
              document.querySelector('[data-review-reset-policy]').dataset.oldStatus = String(result.status)
            }
            return await new Promise((_, reject) => { window.losePolicy = () => reject(new TypeError('Lost response')) })
          }
          return originalFetch(url, options)
        }
      JS
      uncheck "Reset approvals when content changes"
      expect(page).to have_css("[data-review-reset-policy][data-in-flight='true']")
      if newer_choice
        check "Reset approvals when content changes"
        page.execute_script("window.losePolicy()")
      end
      expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
      page.execute_script("window.deliverOldPolicy()")
      expect(page).to have_css("[data-review-reset-policy][data-old-status='409']")
      expect(page).to have_checked_field("Reset approvals when content changes")
      expect(plan.reload.reset_reviews_on_change).to be(true)
    end
  end
  it "keeps a review refresh when policy toggles cancel out", :review_reset_policy do
    sign_in_browser(author)
    open_review_settings
    allow(CoPlan::Broadcaster).to receive(:custom_action_to)
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, generation: task.generation, decision: "approved")
    page.execute_script(<<~JS)
      const root = document.getElementById('plan-review-controls')
      const controller = window.Stimulus.getControllerForElementAndIdentifier(root, 'coplan--review-tray')
      const originalFetch = window.fetch.bind(window)
      let hold = true
      window.fetch = async (url, options) => {
        const result = await originalFetch(url, options)
        if (hold && url === controller.urlValue && !options?.method) {
          hold = false
          root.dataset.refreshHeld = 'true'
          await new Promise(resolve => { window.releaseControls = resolve })
        }
        return result
      }
      controller.refresh()
    JS
    expect(page).to have_css("[data-refresh-held='true']")
    page.execute_script("const input = document.querySelector('[data-review-reset-policy]'); input.click(); input.click(); window.releaseControls()")
    expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
    expect(page).to have_css(".review-person", text: "Approved")
    expect(plan.reload.reset_reviews_on_change).to be(true)
  end

  [ "write body", "readback" ].each do |stall|
    it "releases autosave after a stalled #{stall} and allows retry", :review_reset_policy do
      sign_in_browser(author)
      open_review_settings
      page.execute_script(<<~JS, stall)
        const stall = arguments[0]
        const originalFetch = window.fetch.bind(window)
        const originalTimeout = window.setTimeout.bind(window)
        window.setTimeout = (action, delay, ...args) => originalTimeout(action, delay === 10000 ? 100 : delay, ...args)
        window.fetch = async (url, options) => {
          if (options?.method === 'PATCH' && String(url).endsWith('/settings')) {
            if (stall === 'write body') return {ok: true, status: 200, json: () => new Promise(() => {})}
            throw new TypeError('Lost response')
          }
          if (stall === 'readback' && String(url).endsWith('/review_requests')) return new Promise(() => {})
          return originalFetch(url, options)
        }
        window.restorePolicyNetwork = () => { window.fetch = originalFetch; window.setTimeout = originalTimeout }
      JS
      uncheck "Reset approvals when content changes"
      expect(page).to have_text(/Couldn't confirm|Couldn't reach/)
      expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
      expect(page).to have_checked_field("Reset approvals when content changes", disabled: false)
      page.execute_script("window.restorePolicyNetwork()")
      uncheck "Reset approvals when content changes"
      expect(page).to have_no_css("[data-review-reset-policy][aria-busy='true']")
      expect(plan.reload.reset_reviews_on_change).to be(false)
    end
  end

  it "dismisses an approval after an edit, preserves its snapshot and accepts a fresh review", :version_parity do
    within(".review-tray") { click_button "Approve", exact: true }
    within(".review-confirmation") do
      expect(page).to have_text("Attachments, linked or embedded content")
      click_button "Approve v1", exact: true
    end
    expect(page).to have_css(".review-tray", text: "You approved v1")
    original = task.reload.effective_response.plan_version
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "# Revised\n\nEveryone must review this change.",
      base_revision: 1, actor_type: "human", actor_id: author.id)
    visit plan_page_path(plan)
    expand_plan_section("footnote-approvals")
    expect(page).to have_css(".review-tray", text: "Content changed; review v2 again")
    expect(page).to have_css(".review-person__meta", text: "Content changed; review again")
    expect(task.reload.effective_response).to be_nil
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/version-dismissal-#{theme}.png"))
    end
    within("#footnote-approvals") { click_button "View activity", exact: false }
    within(".review-activity-dialog[open]") do
      expect(page).to have_text("Historical decision")
      click_link "v1 · Markdown snapshot"
    end
    expect(page).to have_text("Exact Markdown source")
    find("summary", text: "Exact Markdown source").click
    expect(page).to have_css("pre code", text: original.content_markdown)
    visit plan_page_path(plan)
    within(".review-tray") { click_button "Approve", exact: true }
    within(".review-confirmation") { click_button "Approve v2", exact: true }
    expect(page).to have_css(".review-tray", text: "You approved v2")
    expect(task.reload.effective_response.plan_version.revision).to eq(2)
  end

  it "rejects a decision opened before a same-version re-request", :version_parity do
    within(".review-tray") { click_button "Approve", exact: true }
    CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: author)
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_css(".review-confirmation [role='alert']", text: "review request changed")
    expect(task.reload).to be_pending
    expect(task.review_responses).to be_empty
    click_button "Close approval", enable_aria_label: true
    within(".review-tray") { click_button "Approve", exact: true }
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window)
      window.fetch = (url, options) => {
        if (options?.method === 'POST' && String(url).endsWith('/respond')) {
          window.fetch = originalFetch
          return Promise.resolve(new Response(JSON.stringify({error: 'Sign in again', code: 'authentication_required', sign_in_path: '/sign_in'}), {status: 401}))
        }
        return originalFetch(url, options)
      }
    JS
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_link("Sign in in a new tab")
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_css(".review-tray", text: "You approved v1")
    expect(task.reload.effective_response.request_generation).to eq(2)
  end

  it "keeps a withdrawn request between its two request cycles", :review_withdrawals do
    sign_in_browser(author)
    click_button "More actions"
    within("#plan-menu") { click_button "Manage reviewers" }
    within(".review-management[open]") do
      click_button "Actions for Plan Reviewer", enable_aria_label: true
      click_button "Remove request"
      expect(page).to have_no_css("[data-review-assignments] .review-person")
    end
    expect(task.reload.status).to eq("withdrawn")
    CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: author)
    visit plan_page_path(plan)
    within("#footnote-approvals") { click_button "View activity", exact: false }
    within(".review-activity-dialog[open]") do
      expect(all(".review-log__event").map { |entry| entry.text.squish }).to eq([
        "Plan Author requested a review from Plan Reviewer",
        "Plan Author withdrew the review request for Plan Reviewer",
        "Plan Author requested a review from Plan Reviewer"
      ])
    end
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/review-withdrawal-history-#{theme}.png"))
    end
  end

  it "offers equal review choices and preserves cancelled feedback without moving the reader" do
    within(".review-tray__actions") do
      expect(page).to have_button("Request changes")
      expect(page).to have_button("Approve", exact: true)
      expect(page).to have_no_button("Discuss")
    end
    styles = page.evaluate_script <<~JS
      Array.from(document.querySelectorAll('.review-tray__actions button')).map(button => {
        const style = getComputedStyle(button);
        return [style.backgroundColor, style.color, style.borderColor, style.fontWeight];
      })
    JS
    expect(styles.length).to eq(2)
    expect(styles.first).to eq(styles.last)
    page.execute_script("window.scrollTo(0, 180)")
    scroll = page.evaluate_script("window.scrollY")
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Can we clarify this boundary?", enable_aria_label: true
    within(".review-tray") { click_button "Cancel" }
    expect(task.reload).to be_pending
    expect(task.review_responses).to be_empty
    expect(page.evaluate_script("window.scrollY")).to eq(scroll)
    within(".review-tray") { click_button "Request changes" }
    expect(page).to have_field("Public review comment", with: "Can we clarify this boundary?", enable_aria_label: true)
  end

  [ [ "Request another review", false ], [ "Remove request", true ] ].each do |action, failed|
    it "keeps reviewer-update progress visible for #{action}", :review_interactions do
      sign_in_browser(author)
      click_button "More actions"
      within("#plan-menu") { click_button "Manage reviewers" }
      dialog = find(".review-management[open]")
      before = dialog.rect
      page.execute_script(<<~JS, failed)
        const original = window.fetch.bind(window)
        const gate = new Promise(resolve => { window.releaseReviewUpdate = resolve })
        window.reviewUpdateFailed = arguments[0]
        window.fetch = (url, options) => {
          if (['PATCH', 'DELETE'].includes(options?.method) && String(url).includes('/review_requests/')) {
            return gate.then(() => window.reviewUpdateFailed
              ? new Response(JSON.stringify({error: 'The update was rejected'}), {status: 422, headers: {'Content-Type': 'application/json'}})
              : original(url, options))
          }
          return original(url, options)
        }
      JS
      # A native popover is visible before its queued toggle event runs.
      # Hold that event back so positioning must happen before it opens.
      page.execute_script <<~JS
        document.querySelector('.review-person__menu').addEventListener('toggle', event => {
          if (event.newState === 'open') event.stopImmediatePropagation()
        }, {capture: true})
      JS
      within(dialog) do
        trigger = find_button("Actions for Plan Reviewer", enable_aria_label: true)
        trigger_rect = trigger.rect
        trigger.click
        menu = find(".review-person__menu:popover-open")
        expect((menu.rect.y - trigger_rect.y - trigger_rect.height - 6).abs).to be <= 1
        expect((menu.rect.x + menu.rect.width - trigger_rect.x - trigger_rect.width).abs).to be <= 1
        click_button action
        expect(page).to have_no_css(".review-person__menu:popover-open")
        expect(page).to have_text("Updating…")
        expect(page).to have_css("[data-review-assignments][aria-busy='true'][inert]")
      end
      expect(dialog.rect).to eq(before)
      [ "light", "dark" ].each do |theme|
        page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
        page.save_screenshot(Rails.root.join("tmp/review-preview/review-management-busy-#{theme}.png"))
      end
      page.execute_script("window.releaseReviewUpdate()")
      expect(page).to have_no_css(".review-management[data-managing]", wait: 15)
      expect(page).to have_no_css("[data-review-assignments][inert]")
      if failed
        expect(dialog).to have_css("[role='alert']", text: "The update was rejected")
        expect(task.reload.status).to eq("pending")
      else
        expect(dialog).to have_no_text("Updating…")
        expect(task.reload).to be_pending
      end
    ensure
      page.execute_script("window.reviewUpdateFailed = true; window.releaseReviewUpdate?.()")
    end
  end

  it "focuses the reply when opening review feedback from the tray and activity", :review_interactions do
    result = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1,
      decision: "changes_requested", note: "Please clarify recovery")
    visit plan_page_path(plan)
    within(".review-tray") { click_button "View feedback" }
    expect(page).to have_css("#comment_thread_#{result.comment_thread_id}_popover:popover-open .thread-popover__reply textarea:focus")
    page.send_keys(:escape)
    within("#footnote-approvals") { click_button "View activity", exact: false }
    within(".review-activity-dialog") { click_button "Open discussion", exact: false }
    expect(page).to have_css("#comment_thread_#{result.comment_thread_id}_popover:popover-open .thread-popover__reply textarea:focus")
  end

  it "records approvals and public change requests on an empty version" do
    # Older hosts can have a persisted empty version, as in plans_spec.
    set_version_fixture(plan.current_plan_version, content_markdown: "", content_sha256: Digest::SHA256.hexdigest(""))
    visit plan_page_path(plan)
    expect(page).to have_content("This plan has no content yet.")
    within(".review-tray") { click_button "Approve", exact: true }
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_css(".review-tray", text: "You approved v1")
    CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: author)
    expect(page).to have_css(".review-tray", text: "Your review is requested")
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "This plan needs content.", enable_aria_label: true
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css(".review-tray", text: "You requested changes to v1")
    expect(page).to have_css("#plan-general-comments .document-comment", text: "This plan needs content.")
    within(find("#plan-general-comments .document-comment", text: "This plan needs content.")) do
      click_button "Open discussion", exact: true, enable_aria_label: true
    end
    expect(page).to have_css(".thread-popover:popover-open", text: "This plan needs content.")
    expect(task.reload.status).to eq("changes_requested")
  end

  it "retries a lost approval after reopening without completing a newly requested review", :review_retries do
    lose_next_review_result
    within(".review-tray") { click_button "Approve", exact: true }
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_css(".review-confirmation [role='alert']", text: "try again")
    first = task.review_responses.last!
    CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: author)
    expect(page).to have_css(".review-tray", text: "Your review is requested")
    click_button "Close approval", enable_aria_label: true
    within(".review-tray") { click_button "Approve", exact: true }
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_no_css(".review-confirmation[open]")
    expect(task.reload.status).to eq("pending")
    expect(task.review_responses.pluck(:id)).to eq([ first.id ])
    within(".review-tray") { click_button "Approve", exact: true }
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_css(".review-tray", text: "You approved")
    expect(task.reload.status).to eq("approved")
    expect(task.review_responses.count).to eq(2)
  end

  it "records changed approval fields as a new intent after an ambiguous failure", :review_retries do
    lose_next_review_result
    within(".review-tray") { click_button "Approve", exact: true }
    fill_in "Public note", with: "First wording"
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_css(".review-confirmation [role='alert']", text: "try again")
    fill_in "Public note", with: "Revised wording"
    within(".review-confirmation") { click_button "Approve v1", exact: true }
    expect(page).to have_no_css(".review-confirmation[open]")
    expect(task.review_responses.pluck(:note)).to contain_exactly("First wording", "Revised wording")
    expect(task.reload.status).to eq("approved")
  end

  it "replays lost change feedback after cancelling and reopening its composer", :review_retries do
    lose_next_review_result
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Keep one copy of this feedback", enable_aria_label: true
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css(".review-tray__discussion [role='alert']", text: "try again")
    first = task.review_responses.last!
    CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: author)
    expect(page).to have_css(".review-tray", text: "Your review is requested")
    within(".review-tray__discussion") { click_button "Cancel" }
    within(".review-tray") { click_button "Request changes" }
    expect(page).to have_field("Public review comment", with: "Keep one copy of this feedback", enable_aria_label: true)
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_no_css(".review-tray__discussion", visible: true)
    expect(task.review_responses.pluck(:id)).to eq([ first.id ])
    expect(task.reload.status).to eq("pending")
    expect(page).to have_content("Your earlier change request was already recorded. Review the current request again.")
    expect(plan.comment_threads.count).to eq(1)
    expect(plan.notifications.where(reason: "review_response").count).to eq(1)
  end

  it "removes feedback links in place when the last review comment is deleted" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Remove this feedback comment", enable_aria_label: true
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css(".review-tray", text: "You requested changes")
    within(".review-tray") { click_button "View feedback" }
    expect(page).to have_css(".thread-popover", text: "Remove this feedback comment", visible: true)
    accept_confirm do
      within(".thread-popover", visible: true) { click_button "Delete", exact: true }
    end
    expect(page).to have_no_css(".thread-popover", visible: true)
    within(".review-tray") { expect(page).to have_no_button("View feedback") }
    click_button "View activity", exact: false
    expect(page).to have_css(".review-activity-dialog[open]")
    within(".review-activity-dialog") do
      expect(page).to have_no_button("Open discussion", exact: false)
      expect(page).to have_text("Remove this feedback comment")
    end
    expect(task.reload.status).to eq("changes_requested")
  end

  it "uses existing comments for change requests and supports another look without erasing the response" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Please explain the retry contract.", enable_aria_label: true
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css(".review-tray", text: "You requested changes to v1")
    expect(page).to have_css("#plan-general-comments", text: "Please explain the retry contract.")
    expect(task.reload.status).to eq("changes_requested")
    sign_in_browser(author)
    click_button "More actions"
    within("#plan-menu") { click_button "Manage reviewers" }
    click_button "Actions for Plan Reviewer"
    click_button "Ready for another look"
    expect(page).to have_css(".review-person", text: "Review requested")
    expect(task.reload).to be_pending
    expect(task.review_responses.count).to eq(1)
  end

  it "confirms approval with simple wording and a top-left close control" do
    within(".review-tray") { click_button "Approve" }
    expect(page).to have_css(".review-confirmation[open]", text: "I’ve reviewed and approve the Markdown source of this version.")
    expect(page).to have_css(".review-confirmation__close:focus")
    expect(page).to have_css("#approval-title", text: "Approve v1?")
    expect(page).to have_no_content("AI agents can see this sign-off")
    expect(page).to have_no_button("Cancel")
    click_button "Close approval", enable_aria_label: true
    expect(task.review_responses).to be_empty
    expect(page).to have_no_css(".review-tray__discussion", visible: true)
    within(".review-tray") { click_button "Approve" }
    fill_in "Public note", with: "Satisfied with this version."
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/approval-dialog-clean-#{theme}.png"))
    end
    close = find(".review-confirmation__close").rect
    title = find("#approval-title").rect
    expect(close.x).to be < title.x
    expect(close.y).to be < title.y
    click_button "Close approval", enable_aria_label: true
    within(".review-tray") { click_button "Approve" }
    expect(page).to have_field("Public note", with: "Satisfied with this version.")
    page.send_keys(:escape)
    expect(page).to have_no_css(".review-confirmation[open]")
    within(".review-tray") { click_button "Approve" }
    click_button "Approve v1"
    expect(page).to have_css(".review-tray:popover-open", text: "You approved v1", wait: 10)
    expect(task.reload.status).to eq("approved")
    expect(page).to have_css("#plan-general-comments", text: "Satisfied with this version.")
    expect(page).to have_css(".review-activity-dialog .review-history", text: /Plan Reviewer approved\s+v1/, visible: :all)
    expect(page).to have_content("Satisfied with this version.")
    within(".review-tray") do
      expect(page).to have_css(".review-result-icon--approved", text: "✓")
      expect(page).to have_no_content("Required")
      expect(page).to have_no_content("Satisfied with this version.")
    end
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.execute_script("document.getElementById('footnote-approvals').scrollIntoView({block: 'center'})")
      page.save_screenshot(Rails.root.join("tmp/review-preview/approval-confirmation-#{theme}.png"))
    end
    expect(page).to have_css(".review-tray time", text: task.review_responses.first.created_at.strftime("%b %-d, %Y"))
    expect(page).to have_link("Reviews", href: "#footnote-approvals")
    expect(page).to have_css("#nav-approvals-count", text: "1", exact_text: true)
    # The receipt survives the former four-second timeout and return visits.
    using_wait_time(6) { page.evaluate_async_script("setTimeout(arguments[0], 4500)") }
    expect(page).to have_css(".review-tray:popover-open", text: "You approved v1")
    visit plan_page_path(plan)
    expect(page).to have_css(".review-tray:popover-open", text: "You approved v1")
    within(".review-tray") { click_button "View feedback" }
    expect(page).to have_css(".thread-popover:popover-open", text: "Satisfied with this version.")
    expect(page).to have_css(".review-tray:popover-open", text: "You approved v1")
  end

  it "refuses sign-off when the viewed version changed and keeps the public note" do
    within(".review-tray") { click_button "Approve" }
    fill_in "Public note", with: "An unsent approval note"
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "Changed while reviewing")
    plan.with_lock { CoPlan::Plans::AdvanceVersion.call(plan: plan, version: version) }
    click_button "Approve v1"
    expect(page).to have_content("The plan has changed. Review the latest version")
    expect(page).to have_field("Public note", with: "An unsent approval note")
    expect(task.review_responses).to be_empty
  end

  it "keeps feedback tied to the version shown when composition began" do
    within(".review-tray") { click_button "Request changes" }
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Changed while composing feedback",
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    expect(page).to have_css('#plan-content-body[data-coplan--live-update-revision-value="2"]', text: "Changed while composing feedback")
    fill_in "Public review comment", with: "My feedback on the earlier version", enable_aria_label: true
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_content("The plan has changed. Review the latest version")
    expect(page).to have_field("Public review comment", with: "My feedback on the earlier version", enable_aria_label: true)
    expect(task.review_responses).to be_empty
    expect(task.reload.status).to eq("pending")
    within(".review-tray__discussion") { click_button "Cancel" }
    within(".review-tray") { click_button "Request changes" }
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css(".review-tray", text: "You requested changes to v2")
    expect(task.review_responses.last!.plan_version.revision).to eq(2)
  end

  it "compares later edits while preserving the approval of the earlier version" do
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "A clarified retry contract.")
    plan.with_lock { CoPlan::Plans::AdvanceVersion.call(plan: plan, version: version) }
    visit plan_page_path(plan)
    within("#footnote-approvals") { click_button "Compare", exact: false }
    expect(page).to have_css(".review-comparison[open]", text: "Version 1 → 2")
    expect(page).to have_content("A clarified retry contract.")
    expect(page).to have_content("The earlier approval remains recorded")
    expect(task.reload.status).to eq("pending")
    expect(task.latest_approval.plan_version.revision).to eq(1)
  end

  it "retains drafts on failure and on live review refreshes" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Keep this unsent comment", enable_aria_label: true
    task.update!(requirement: "optional")
    page.execute_script("document.getElementById('plan-review-controls').dispatchEvent(new CustomEvent('coplan:reviews-changed'))")
    expect(page).to have_css("[data-review-status]", text: "Optional")
    expect(page).to have_field("Public review comment", with: "Keep this unsent comment", enable_aria_label: true)
    expect(page).to have_css(".review-tray__discussion", visible: true)
    page.execute_script <<~JS
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (options?.method === 'POST') {
          window.fetch = originalFetch;
          return Promise.reject(new TypeError('Failed to fetch'));
        }
        return originalFetch(url, options);
      };
    JS
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css("#review-discussion-error", text: "Couldn't reach CoPlan. Your draft is still here")
    expect(page).to have_field("Public review comment", with: "Keep this unsent comment", enable_aria_label: true)
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css(".review-tray", text: "You requested changes to v1")
  end

  it "lets the author find a person and assign required or optional review" do
    other = create(:coplan_user, username: "new-reviewer", name: "Another Reviewer", email: "another-reviewer@example.com")
    task.update!(status: "withdrawn")
    sign_in_browser(author)
    expect(page).to have_no_css(".review-tray", visible: :all)
    click_button "More actions"
    within("#plan-menu") { click_button "Manage reviewers" }
    within(".review-management") { click_button "Add reviewer", exact: true }
    fill_in "Find a reviewer", with: "Another Reviewer"
    expect(page).to have_css(".review-search-result", text: "Another Reviewer")
    find(".review-search-result", text: "Another Reviewer").click
    uncheck "Required"
    within(".review-assignment-form") { click_button "Add reviewer", exact: true }
    expect(page).to have_css(".review-person", text: "Another Reviewer")
    expect(plan.review_requests.find_by!(reviewer: other).requirement).to eq("optional")
    expect(page).to have_no_css(".review-tray", visible: :all)
    sign_in_browser(other)
    expect(page).to have_css(".review-tray", visible: true)
  end

  it "assigns a directory result using the matching local identity", :review_directory do
    other = create(:coplan_user, username: "directory-reviewer", name: "Local Reviewer")
    previous_search = CoPlan.configuration.user_search
    CoPlan.configuration.user_search = ->(_query) {
      [ { "id" => "external-directory-id", "username" => other.username, "name" => "Directory Reviewer", "team" => "Directory Team" } ]
    }
    sign_in_browser(author)
    click_button "More actions"
    within("#plan-menu") { click_button "Manage reviewers" }
    within(".review-management") { click_button "Add reviewer", exact: true }
    fill_in "Find a reviewer", with: "Directory Reviewer"
    result = find(".review-search-result", text: "Directory Reviewer")
    expect(result["data-user-id"]).to eq(other.id)
    result.click
    within(".review-assignment-form") { click_button "Add reviewer", exact: true }
    expect(page).to have_css(".review-person", text: "Local Reviewer")
    expect(plan.review_requests.find_by!(reviewer: other).requirement).to eq("required")
  ensure
    CoPlan.configuration.user_search = previous_search
  end

  it "offers the host's suggested reviewers with their requirement", :review_suggestions do
    owner = create(:coplan_user, username: "code-owner", name: "Code Owner")
    previous_hook = CoPlan.configuration.suggest_reviewers
    CoPlan.configuration.suggest_reviewers = ->(_plan) {
      [ reviewer, { user: owner, reason: "Owns app/models/user.rb", requirement: "optional" } ]
    }
    sign_in_browser(author)
    click_button "More actions"
    within("#plan-menu") { click_button "Manage reviewers" }
    within(".review-management") { click_button "Add reviewer", exact: true }
    within(".review-suggestions") do
      expect(page).to have_css(".review-search-result", count: 1)
      expect(page).to have_css(".review-search-result", text: "Code Owner\nOwns app/models/user.rb · Optional")
    end
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/reviewer-suggestions-#{theme}.png"))
    end
    find(".review-suggestions .review-search-result", text: "Code Owner").click
    expect(page).to have_field("Find a reviewer", with: "Code Owner")
    expect(page).to have_unchecked_field("Required")
    within(".review-assignment-form") { click_button "Add reviewer", exact: true }
    expect(page).to have_css(".review-person", text: "Code Owner")
    expect(plan.review_requests.find_by!(reviewer: owner).requirement).to eq("optional")
  ensure
    CoPlan.configuration.suggest_reviewers = previous_hook
  end

  it "keeps the manager and assignment stable while search results overlay beneath the field" do
    create(:coplan_user, name: "Popover Candidate", username: "popover-candidate")
    sign_in_browser(author)
    click_button "More actions"
    within("#plan-menu") { click_button "Manage reviewers" }
    manager = find(".review-management").rect
    within(".review-management") { click_button "Add reviewer", exact: true }
    expect(page).to have_css("#review-assignment:popover-open")
    expect(page).to have_css('[aria-controls="review-assignment"][aria-expanded="true"]')
    find('[popovertarget="review-assignment"]').click
    expect(page).to have_no_css("#review-assignment:popover-open")
    within(".review-management") { click_button "Add reviewer", exact: true }
    expect(page).to have_css("#review-assignment:popover-open")
    # Native toggle is queued after opening. Record geometry only after the
    # handler has positioned the picker and focused its search field.
    expect(page).to have_css('[aria-controls="review-assignment"][aria-expanded="true"]')
    expect(page).to have_css("#reviewer-search:focus")
    panel = find("#review-assignment").rect
    expect(find(".review-management").rect).to eq(manager)
    fill_in "Find a reviewer", with: "Popover Candidate"
    expect(page).to have_css(".review-search-result", text: "Popover Candidate")
    expect(find("#review-assignment").rect).to eq(panel)
    expect(find(".review-management").rect).to eq(manager)
    field = find("#reviewer-search").rect
    results = find("#reviewer-results").rect
    expect(results.y).to be >= field.y + field.height
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/reviewer-popover-#{theme}.png"))
    end
    fill_in "Find a reviewer", with: "NoSuchPerson98765"
    expect(page).to have_css("#reviewer-results", text: "No people found")
    expect(find("#review-assignment").rect).to eq(panel)
    page.send_keys(:escape)
    expect(page).to have_no_css("#review-assignment:popover-open")
    expect(page).to have_css(".review-management[open]")
    expect(page).to have_css('[aria-controls="review-assignment"]:focus')
    within(".review-management") { click_button "Add reviewer", exact: true }
    page.current_window.resize_to(360, 760)
    fill_in "Find a reviewer", with: "Popover Candidate"
    expect(page).to have_css(".review-search-result", text: "Popover Candidate")
    [ "#review-assignment", "#reviewer-results" ].each do |selector|
      rect = find(selector).rect
      expect(rect.x).to be >= 0
      expect(rect.x + rect.width).to be <= page.evaluate_script("window.innerWidth")
      expect(rect.y + rect.height).to be <= page.evaluate_script("window.innerHeight")
    end
    find(".review-search-result", text: "Popover Candidate").click
    expect(page).to have_button("Add reviewer", disabled: false, count: 2)
    click_button "Close reviews", enable_aria_label: true
    expect(page).to have_no_css("#review-assignment:popover-open")
  ensure
    page.current_window.resize_to(1400, 900)
  end

  it "shows submitted feedback and lets a reviewer reconsider without erasing history" do
    general = create(:comment_thread, plan: plan, created_by_user: author)
    general.comments.create!(author_type: "human", author_id: author.id, body_markdown: "**Whole plan feedback**")
    general.comments.create!(author_type: "human", author_id: reviewer.id, body_markdown: "A follow-up")
    displaced = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Some content here.")
    displaced.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Feedback on earlier text")
    displaced.update_columns(out_of_date: true)
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-general-comments .document-comment", text: "Plan comment")
    expect(page).to have_css("#plan-general-comments .document-comment__open[title='1 reply']")
    expect(page).to have_css("#plan-general-comments .comment__body strong", text: "Whole plan feedback")
    find("#plan-general-comments summary").click
    expect(page).to have_no_css("#plan-general-comments .document-comment", visible: true)
    page.execute_script("document.getElementById('plan-review-controls').dispatchEvent(new CustomEvent('coplan:reviews-changed'))")
    expect(page).to have_no_css("#plan-general-comments details[open]")
    within("#footnote-approvals") { expect(page).to have_content("Review requested") }
    find("#plan-general-comments summary").click
    expect(page).to have_css("#plan-detached-comments .document-comment", text: "Earlier text")
    within(".review-tray") { click_button "Request changes" }
    expect(page).to have_button("Request changes", count: 1)
    fill_in "Public review comment", with: "Please verify recovery.", enable_aria_label: true
    within(".review-tray__discussion") { click_button "Request changes" }
    within(".review-tray") do
      expect(page).to have_content("You requested changes to v1")
      expect(page).to have_no_content("Please verify recovery.")
      expect(page).to have_no_button("Request changes")
      expect(page).to have_button("View feedback", exact: false)
      click_button "Change decision"
      click_button "Approve", exact: true
    end
    click_button "Close approval", enable_aria_label: true
    within(".review-tray") { click_button "Request changes" }
    within(".review-tray") { click_button "Cancel" }
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.execute_script("document.getElementById('plan-general-comments').scrollIntoView({block: 'center'})")
      page.save_screenshot(Rails.root.join("tmp/review-preview/review-receipt-comments-#{theme}.png"))
    end
    page.current_window.resize_to(360, 760)
    expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= page.evaluate_script("window.innerWidth")
    page.current_window.resize_to(1400, 900)
    within("#footnote-approvals") { click_button "Change decision", enable_aria_label: true }
    within(".review-tray") { click_button "Approve", exact: true }
    click_button "Approve v1"
    expect(page).to have_css(".review-tray", text: "You approved v1")
    expect(task.reload.status).to eq("approved")
    expect(task.review_responses.count).to eq(2)
    expect(page).to have_css("#plan-general-comments .document-comment", text: "Review · Changes requested · v1")
    within(find("#plan-general-comments .document-comment", text: "Please verify recovery.")) { click_button "Open discussion", exact: false, enable_aria_label: true }
    expect(page).to have_css(".thread-popover:popover-open", text: "Please verify recovery.")
  ensure
    page.current_window.resize_to(1400, 900)
  end

  it "shows aligned approval columns and versions only for recorded decisions" do
    other = create(:coplan_user, name: "Another Reviewer")
    create(:review_request, plan: plan, reviewer: other, requirement: "optional")
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    visit plan_page_path(plan)
    within(".review-table") do
      expect(all("th").map(&:text)).to eq([ "Reviewer", "Review", "Decision", "Version", "Actions" ])
      rows = all("tbody tr")
      expect(rows.map { |row| row.find("strong").text }).to eq([ "Plan Reviewer", "Another Reviewer" ])
      expect(rows.first.all("td").map { |cell| cell.text.gsub(/\s+/, " ") }.first(4)).to eq([ "PR Plan Reviewer", "Required", "✓ Approved", "v1" ])
      expect(rows.last.all("td")[3].text).to eq("—")
      expect(rows.first).to have_button("Change decision", enable_aria_label: true)
      expect(rows.first.find(".review-reopen").text).to be_empty
    end
    expect(page).to have_no_link("Attachments", href: "#footnote-attachments")
  end

  it "keeps reviews navigation available for historical review records" do
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    task.update!(status: "withdrawn")
    visit plan_page_path(plan)
    expect(page).to have_link("Reviews", href: "#footnote-approvals")
    expect(page).to have_css("#nav-approvals-count", text: "1", exact_text: true)
    page.execute_script("document.getElementById('plan-review-controls').dispatchEvent(new CustomEvent('coplan:reviews-changed'))")
    expect(page).to have_link("Reviews", href: "#footnote-approvals")
    expect(page).to have_css("#nav-approvals-count", text: "1", exact_text: true)
    within("#footnote-approvals") { click_button "View activity" }
    expect(page).to have_css(".review-activity-dialog[open]", text: "Plan Reviewer approved")
  end

  it "preserves the long roster position during live review updates" do
    12.times { create(:review_request, plan: plan, reviewer: create(:coplan_user)) }
    visit plan_page_path(plan)
    page.execute_script("document.querySelector('.review-table-scroll').scrollTop = 180")
    expect(page.evaluate_script("document.querySelector('.review-table-scroll').scrollTop")).to eq(180)
    task.update!(requirement: "optional")
    page.execute_script("document.getElementById('plan-review-controls').dispatchEvent(new CustomEvent('coplan:reviews-changed'))")
    expect(page).to have_css(".review-table tr[data-reviewer-id='#{reviewer.id}']", text: "Optional")
    expect(page.evaluate_script("document.querySelector('.review-table-scroll').scrollTop")).to eq(180)
    expect(page).to have_link("Reviews", href: "#footnote-approvals")
    expect(page).to have_css("#nav-approvals-count", text: "13", exact_text: true)
  end

  it "extends comment hover backgrounds to the section edges with padded content" do
    thread = create(:comment_thread, plan: plan, created_by_user: author)
    thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "A document-wide discussion")
    visit plan_page_path(plan)
    [ [ 1400, 900 ], [ 360, 760 ] ].each do |width, height|
      page.current_window.resize_to(width, height)
      comment = find("#plan-general-comments .document-comment")
      page.execute_script("arguments[0].scrollIntoView({block: 'center'})", comment)
      comment.hover
      geometry = page.evaluate_script <<~JS
        (() => {
        const row = document.querySelector('#plan-general-comments .document-comment');
        const section = document.getElementById('plan-general-comments').getBoundingClientRect();
        const rect = row.getBoundingClientRect();
        const header = row.querySelector('.document-comment__header').getBoundingClientRect();
        return {left: rect.left - section.left, right: section.right - rect.right, padding: header.left - rect.left, overflow: document.documentElement.scrollWidth > innerWidth};
        })()
      JS
      expect(geometry["left"].abs).to be <= 1
      expect(geometry["right"].abs).to be <= 1
      expect(geometry["padding"]).to be >= 12
      expect(geometry["overflow"]).to be(false)
      [ "light", "dark" ].each do |theme|
        page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
        comment.hover
        page.save_screenshot(Rails.root.join("tmp/review-preview/comment-hover-#{width}-#{theme}.png"))
      end
      within(".review-tray") { click_button "Approve" }
      expect(find(".review-confirmation").rect.width).to be <= page.evaluate_script("innerWidth")
      click_button "Close approval", enable_aria_label: true
    end
  ensure
    page.current_window.resize_to(1400, 900)
  end

  it "opens comment rows and reveals filtered resolved feedback from activity", :review_interactions do
    result = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "changes_requested", note: "Please clarify recovery")
    thread = result.comment_thread
    thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "I added the recovery detail")
    visit plan_page_path(plan)
    comment = find("#plan-general-comments .document-comment", text: "Please clarify recovery")
    expect(comment).to have_button("Open discussion", enable_aria_label: true)
    expect(comment.find(".document-comment__open")[:title]).to eq("1 reply")
    comment.find(".comment__body").click
    expect(page).to have_css(".thread-popover:popover-open", text: "I added the recovery detail")
    page.send_keys(:escape)
    thread.resolve!(reviewer)
    visit plan_page_path(plan)
    expect(page).to have_no_css("#plan-general-comments .document-comment", text: "Please clarify recovery")
    within("#footnote-approvals") { click_button "View activity", exact: false }
    within(".review-activity-dialog") { click_button "Open discussion", exact: false }
    expect(page).to have_no_css(".review-activity-dialog[open]")
    expect(page).to have_css(".thread-popover:popover-open", text: "Please clarify recovery")
    expect(page).to have_select("Show", selected: "Resolved")
    expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open .comment-window__move:focus")
    expect(thread.reload.status).to eq("resolved")
  end

  it "starts collapsed and uses the normal comment window without losing drafts", :collapsed_support do
    resolved = create(:comment_thread, plan: plan, created_by_user: author, status: "resolved")
    resolved.comments.create!(author_type: "human", author_id: author.id, body_markdown: "An earlier discussion")
    page.execute_script <<~JS
      for (const id of ['footnote-approvals', 'plan-general-comments']) {
        sessionStorage.setItem(`coplan-support:${location.pathname}:${id}`, 'true');
      }
    JS
    visit plan_page_path(plan)
    expect(page).to have_link("Comments", href: "#plan-general-comments")
    expect(page).to have_no_css("#plan-general-comments details[open]")
    expect(page).to have_no_css("#footnote-approvals details[open]")
    expect(page).to have_no_css("#plan-general-comments textarea", visible: :all)
    scroll = page.evaluate_script("window.scrollY")
    within("#plan-general-comments") { click_button "Add comment" }
    expect(page).to have_css("#new-comment-form.comment-window:popover-open textarea:focus")
    expect(page.evaluate_script("window.scrollY")).to eq(scroll)
    expect(page).to have_no_css("#plan-general-comments details[open]")
    within("#new-comment-form") do
      fill_in "New comment", with: "A new document discussion", enable_aria_label: true
      click_button "Comment", exact: true
    end
    expect(page).to have_no_css("#new-comment-form:popover-open")
    expect(page.evaluate_script("window.scrollY")).to eq(scroll)
    within("#plan-general-comments") do
      expect(page).to have_css("details[open]")
      expect(page).to have_css(".document-comment", text: "A new document discussion")
      expect(page).to have_select("Show", selected: "Open")
      expect(page).to have_no_content("An earlier discussion")
      select "Resolved", from: "Show"
      expect(page).to have_content("An earlier discussion")
      click_button "Add comment"
    end
    within("#new-comment-form") { fill_in "New comment", with: "Keep this draft during updates", enable_aria_label: true }
    thread = plan.comment_threads.joins(:comments).find_by!(coplan_comments: { body_markdown: "A new document discussion" })
    expect(thread.anchor_text).to be_blank
    expect(thread.created_by_user).to eq(reviewer)
    thread.resolve!(reviewer)
    CoPlan::Comments::RefreshPreviews.call(thread: thread)
    page.execute_script("document.getElementById('plan-review-controls').dispatchEvent(new CustomEvent('coplan:reviews-changed'))")
    expect(page).to have_field("New comment", with: "Keep this draft during updates", enable_aria_label: true)
    within("#plan-general-comments") do
      select "All comments", from: "Show"
      expect(page).to have_content("An earlier discussion")
      expect(page).to have_content("A new document discussion")
      click_button "Add comment"
    end
    expect(page).to have_field("New comment", with: "Keep this draft during updates", enable_aria_label: true)
    within("#new-comment-form") { click_button "Cancel" }
    expect(page).to have_css('#plan-general-comments [aria-label="Add comment"]:focus')
  end

  it "records a changed decision after reopening the plan and preserves both decisions" do
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    visit plan_page_path(plan)
    within("#footnote-approvals") { click_button "Change decision", enable_aria_label: true }
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "I reconsidered the recovery step", enable_aria_label: true
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css(".review-tray", text: "You requested changes to v1")
    expect(task.reload.status).to eq("changes_requested")
    expect(task.review_responses.count).to eq(2)
    within("#footnote-approvals") { click_button "View activity", exact: false }
    expect(page).to have_css(".review-activity-dialog[open]", text: "I reconsidered the recovery step")
    within(".review-activity-dialog") { click_button "Open discussion", exact: false, enable_aria_label: true }
    expect(page).to have_no_css(".review-activity-dialog[open]")
    expect(page).to have_css(".thread-popover:popover-open", text: "I reconsidered the recovery step")
  end

  it "explains an expired login and keeps review feedback available for retry" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Don't lose this feedback", enable_aria_label: true
    page.execute_script <<~JS
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (options?.method === 'POST') {
          window.fetch = originalFetch;
          return Promise.resolve(new Response(JSON.stringify({error: 'Your session ended. Sign in, then retry; your draft is still here.', code: 'authentication_required', sign_in_path: '/sign_in'}), {status: 401, headers: {'Content-Type': 'application/json'}}));
        }
        return originalFetch(url, options);
      };
    JS
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_content("Your session ended")
    expect(page).to have_link("Sign in in a new tab", href: "/sign_in")
    expect(page).to have_field("Public review comment", with: "Don't lose this feedback", enable_aria_label: true)
    expect(task.review_responses).to be_empty
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css(".review-tray", text: "You requested changes to v1")
    expect(task.reload.status).to eq("changes_requested")
  end

  it "collapses the log and opens it again from the Reviews sidebar" do
    find("#footnote-approvals summary").click
    expect(page).to have_no_css("#footnote-approvals .review-roster", visible: true)
    click_link "Reviews", href: "#footnote-approvals"
    expect(page).to have_css("#footnote-approvals .review-roster", visible: true)
    expect(page).to have_no_css("[data-review-log-summary] .review-version")
    expect(page).to have_css(".review-person__meta", text: "Review requested")
    expect(page).to have_no_css(".review-person__meta", text: "v1")
  end

  it "acknowledges saved feedback even if refreshing its comment fails" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "A saved request", enable_aria_label: true
    page.execute_script <<~JS
      const originalFetch = window.fetch;
      const commentsUrl = document.querySelector('[data-coplan--inline-editor-comments-url-value]').getAttribute('data-coplan--inline-editor-comments-url-value');
      window.fetch = (url, options) => {
        if (url === commentsUrl) {
          window.fetch = originalFetch;
          return Promise.reject(new TypeError('Failed to fetch'));
        }
        return originalFetch(url, options);
      };
    JS
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css(".review-tray__notice", text: "Refresh the page to see your comment.", visible: :all)
    expect(task.reload.review_responses.count).to eq(1)
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-general-comments", text: "A saved request")
  end

  it "orders required reviewers first and keeps management actions in dropdowns" do
    other = create(:coplan_user, name: "Another Reviewer")
    optional = create(:review_request, plan: plan, reviewer: other, requirement: "optional", requested_at: 1.day.ago)
    sign_in_browser(author)
    click_button "More actions"
    within("#plan-menu") { click_button "Manage reviewers" }
    within(".review-management") do
      expect(page).to have_no_css("h3, .review-management__eyebrow")
      expect(all(".review-person strong").map(&:text)).to eq([ "Plan Reviewer", "Another Reviewer" ])
      expect(all(".review-person__requirement").map(&:text)).to eq([ "Required", "Optional" ])
      expect(page).to have_no_button("Make required")
      click_button "Actions for Another Reviewer", enable_aria_label: true
      click_button "Make required"
      expect(page).to have_css(".review-person__requirement", text: "Required", count: 2)
      expect(page).to have_no_css(".review-person__requirement", text: "Optional")
    end
    expect(optional.reload.requirement).to eq("required")
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/review-manager-#{theme}.png"))
    end
    click_button "Close reviews", enable_aria_label: true
    within("#footnote-approvals") { expect(page).to have_css(".review-table__requirement", text: "Required", count: 2) }
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/review-log-#{theme}.png"))
    end
  end

  it "uses the Reviews sidebar and keeps completed decisions attached to their version", :review_history do
    expect(page).to have_no_css("#plan-header [data-review-indicator]", visible: :all)
    click_link "Reviews", href: "#footnote-approvals"
    expect(page.evaluate_script("document.activeElement.id")).to eq("footnote-approvals")
    within("#footnote-approvals") { click_button "View activity", exact: false }
    expect(page).to have_css(".review-activity-dialog[open]", text: "requested a review from Plan Reviewer")
    click_button "Close review activity", enable_aria_label: true
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "# Revised contract\n\nMore detail")
    plan.with_lock { CoPlan::Plans::AdvanceVersion.call(plan: plan, version: version) }
    visit plan_page_path(plan)
    expect(page).to have_no_css("#plan-header [data-review-indicator]", visible: :all)
    within(".review-table") do
      expect(page).to have_css(".review-person__meta", text: "Content changed; review again")
      expect(page).to have_button("Compare")
    end
    expect(page).to have_css(".review-activity-dialog .review-history", text: /Plan Reviewer approved\s+v1/, visible: :all)
    CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: author)
    visit plan_page_path(plan)
    within("#footnote-approvals") { click_button "View activity", exact: false }
    within(".review-activity-dialog[open]") do
      expect(page).to have_css(".review-log__entry", count: 3)
      expect(page).to have_css(".review-log__event", text: "requested a review from Plan Reviewer", count: 2)
      expect(page).to have_css(".review-log__event", text: /Plan Reviewer approved\s+v1/, count: 1)
    end
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/review-request-history-#{theme}.png"))
    end
  end

  it "changes visibility through the byline without navigation or scroll jumps" do
    sign_in_browser(author)
    page.execute_script("window.scrollTo(0, 40)")
    scroll = page.evaluate_script("window.scrollY")
    click_button "Shared", exact: true
    within(".plan-visibility-panel") { click_button "Private", exact: false }
    expect(page).to have_button("Private", exact: true)
    expect(page).to have_css(".plan-visibility-button:focus", text: "Private")
    expect(plan.reload).to be_draft
    expect(page).to have_current_path(plan_page_path(plan))
    expect(page.evaluate_script("window.scrollY")).to eq(scroll)
    click_button "Private", exact: true
    within(".plan-visibility-panel") { click_button "Shared", exact: false }
    expect(page).to have_button("Shared", exact: true)
    expect(plan.reload).to be_published
  end

  it "offers only permitted visibility actions and restores them after unarchiving" do
    plan.update!(archived_at: Time.current)
    sign_in_browser(author)
    click_button "Shared", exact: true
    within(".plan-visibility-panel") do
      expect(page).to have_content("Unlisted. Anyone with the link can read.")
      expect(page).to have_no_button
    end
    page.send_keys(:escape)
    within(".plan-banner--archived") { click_button "Restore" }
    expect(page).to have_no_css(".plan-banner--archived")
    click_button "Shared", exact: true
    within(".plan-visibility-panel") { click_button "Private", exact: false }
    expect(page).to have_button("Private", exact: true)
    expect(page).to have_no_css(".plan-visibility-panel:popover-open")
    expect(plan.reload).to be_draft
    click_button "Private", exact: true
    within(".plan-visibility-panel") { click_button "Shared", exact: false }
    expect(page).to have_button("Shared", exact: true)
    expect(page).to have_no_css(".plan-visibility-panel:popover-open")
    expect(plan.reload).to be_published
  end

  it "shows visibility to readers without exposing author controls" do
    click_button "Shared", exact: true
    within(".plan-visibility-panel") do
      expect(page).to have_content("Listed for everyone in the organization.")
      expect(page).to have_no_button
    end
    expect(page).to have_css(".plan-visibility-panel:focus")
    page.send_keys(:escape)
    expect(page).to have_css(".plan-visibility-button:focus", text: "Shared")
  end

  it "preserves unsent feedback when an open review request is withdrawn" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "An unfinished review", enable_aria_label: true
    task.update!(status: "withdrawn")
    page.execute_script("document.getElementById('plan-review-controls').dispatchEvent(new CustomEvent('coplan:reviews-changed'))")
    expect(page).to have_content("This review request is no longer active. Your unsent feedback is still here.")
    expect(page).to have_field("Public review comment", with: "An unfinished review", enable_aria_label: true)
    within(".review-tray__discussion") { expect(page).to have_button("Request changes", disabled: true) }
    expect(page).to have_no_css(".review-tray__actions button", text: "Approve")
  end

  it "uses the existing dictation composer and keeps the bar within narrow screens in both themes" do
    within(".review-tray") { click_button "Request changes" }
    expect(page).to have_css('.review-tray [data-controller="coplan--dictation"]')
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/tray-#{theme}.png"))
    end
    fill_in "Public review comment", with: "A draft for mobile", enable_aria_label: true
    page.current_window.resize_to(360, 760)
    tray = find(".review-tray").rect
    expect(tray.x).to be >= 0
    expect(tray.x + tray.width).to be <= page.evaluate_script("window.innerWidth")
    expect(page).to have_field("Public review comment", with: "A draft for mobile", enable_aria_label: true)
    expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= page.evaluate_script("window.innerWidth")
  ensure
    page.current_window.resize_to(1400, 900)
  end
end
