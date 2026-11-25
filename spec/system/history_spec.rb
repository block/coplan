require "rails_helper"

RSpec.describe "Plan history page", type: :system do
  let(:user) { create(:coplan_user, email: "histuser@example.com") }

  let(:plan_content) do
    <<~MARKDOWN
      # History Plan

      - [ ] First task
      - [ ] Second task
    MARKDOWN
  end

  let(:plan) do
    p = Coplan::Plan.create!(title: "History Plan", created_by_user: user)
    version = Coplan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: plan_content,
      actor_type: "human", actor_id: user.id,
      change_summary: "Initial draft"
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  describe "navigation" do
    it "reaches history via the toolbar's overflow menu and returns via the back link" do
      visit plan_page_path(plan)

      expect(page).to have_content("First task")
      expect(page).not_to have_content("Initial draft")

      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { click_link "History" }

      expect(page).to have_css("h1", exact_text: "History")
      within(".site-nav") { expect(page).to have_link(plan.title, href: plan_page_path(plan)) }
      expect(page).to have_content("Initial draft")
      expect(page).to have_link("v1")
      expect(page).not_to have_css(".markdown-rendered")

      find(".history-back").click
      expect(page).to have_content("First task")
    end

    it "redirects old ?tab=history links to the history page" do
      visit plan_page_path(plan, tab: "history")

      expect(page).to have_content("Initial draft")
      expect(page).to have_link("v1")
      expect(current_path).to eq(plan_history_page_path(plan))
    end

    it "goes back to the document with Backspace" do
      visit plan_page_path(plan)
      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { click_link "History" }
      expect(page).to have_content("Initial draft")

      find("body").send_keys(:backspace)
      expect(page).to have_content("First task")
    end
  end

  describe "live update via Turbo Streams" do
    it "shows only one audit entry after permanent-deletion broadcasts are replayed" do
      thread = create(:comment_thread, plan: plan)
      event = Coplan::PlanEvent.create!(plan: plan, event_type: "comment_permanently_deleted", actor_type: "human", actor_id: user.id,
        metadata: { "comment_id" => SecureRandom.uuid, "thread_id" => thread.id })
      visit plan_history_page_path(plan)
      expect(page).to have_content("Permanently deleted comment")
      page.execute_script(<<~JS)
        document.documentElement.dataset.historyPrepends = "0"
        document.addEventListener("turbo:before-stream-render", event => {
          if (event.target.getAttribute("action") === "prepend" && event.target.getAttribute("target") === "plan-history-list") {
            document.documentElement.dataset.historyPrepends = String(Number(document.documentElement.dataset.historyPrepends) + 1)
          }
        })
      JS

      2.times { Coplan::BroadcastPermanentCommentDeletionJob.perform_now(event_id: event.id, user_ids: []) }
      expect(page).to have_css("html[data-history-prepends='2']", visible: :all)
      expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(event)}", count: 1)
      expect(page).to have_css("#plan-history-list .history-split__item", count: 2)
    end

    it "shows a new version created while the history page is open" do
      # Create v2 after opening history — the broadcast prepends it live.
      visit plan_history_page_path(plan)

      expect(page).to have_css("#plan-history-list .history-split__item", count: 1)
      expect(page).to have_link("v1")

      Coplan::Plans::ReplaceContent.call(
        plan: plan.reload,
        new_content: plan_content + "\nMore.\n",
        base_revision: plan.current_revision,
        actor_type: "human",
        actor_id: user.id,
        change_summary: "Follow-up edit"
      )

      expect(page).to have_link("v2", wait: 5)
      expect(page).to have_content("Follow-up edit")
      expect(page).to have_select("To", selected: "v1", with_options: [ "v2" ])
      expect(page).to have_css("[data-revision='2'] .history-split__stats", text: "+2")
    end
  end

  describe "inline diff preview" do
    it "auto-loads the latest version's diff in the detail pane" do
      visit plan_history_page_path(plan)

      expect(page).to have_css("#version-diff")
      expect(page).to have_link("View v1", exact: true)
      expect(current_path).to eq(plan_history_page_path(plan))
    end

    it "renders compact edit metadata when the summary is absent" do
      add_revision(2, summary: nil)
      visit plan_history_page_path(plan)

      expect(page).to have_css("[data-revision='2'] .history-split__stats")
      expect(page).to have_no_css("[data-revision='2'] .history-split__summary")
      expect(page).to have_css("#version-diff .version-diff-preview__byline", text: user.name)
      expect(page).to have_no_css("#version-diff .version-diff-preview__summary")
    end
  end

  it "matches the plan header gap and scrolls both History panes within the viewport" do
    original_size = page.current_window.size
    page.current_window.resize_to(898, 794)

    visit plan_page_path(plan)
    plan_header_gap = page.evaluate_script(<<~JS)
      document.querySelector(".plan-document").getBoundingClientRect().top -
        document.querySelector(".plan-masthead").getBoundingClientRect().bottom
    JS

    (2..9).each { |revision| add_revision(revision) }
    Coplan::Plans::ReplaceContent.call(
      plan: plan.reload,
      new_content: "# History Plan\n\n" + (1..80).map { |number| "New paragraph #{number}.\n\n" }.join,
      base_revision: plan.current_revision,
      actor_type: "human", actor_id: user.id
    )
    visit plan_history_page_path(plan)
    expect(page).to have_css("#version-diff", text: "New paragraph 80.")

    geometry = page.evaluate_script(<<~JS)
      (() => {
        const header = document.querySelector(".history-heading")
        const card = document.querySelector(".history-page")
        const toolbar = document.querySelector(".history-comparison")
        const list = document.querySelector("#plan-history-list")
        const diff = document.querySelector(".history-split__diff")
        const gap = card.getBoundingClientRect().top - header.getBoundingClientRect().bottom
        const toolbarTop = toolbar.getBoundingClientRect().top
        window.scrollTo(0, document.scrollingElement.scrollHeight)
        list.scrollTop = list.scrollHeight
        diff.scrollTop = diff.scrollHeight
        return {
          gap, outerScroll: window.scrollY, listScroll: list.scrollTop,
          diffScroll: diff.scrollTop,
          toolbarMove: toolbar.getBoundingClientRect().top - toolbarTop
        }
      })()
    JS
    expect(geometry["gap"]).to be_within(1).of(plan_header_gap)
    expect(geometry["outerScroll"]).to eq(0)
    expect(geometry["listScroll"]).to be_positive
    expect(geometry["diffScroll"]).to be_positive
    expect(geometry["toolbarMove"]).to eq(0)
  ensure
    page.current_window.resize_to(*original_size)
  end

  describe "contiguous revision selection" do
    before do
      (2..4).each { |revision| add_revision(revision) }
    end

    it "compares two snapshots and restores the selected endpoints after reloading" do
      visit plan_history_page_path(plan)
      expect(page).to have_select("From", selected: "v3")
      expect(page).to have_select("To", selected: "v4")
      select "v1", from: "From"

      expect(page).to have_css(".history-split__item--active", count: 3)
      expect(page).to have_css("[data-revision='4'] a[aria-current='true']")
      within("#version-diff") do
        expect(page).to have_no_css(".version-diff-preview__byline, .version-diff-preview__summary")
        expect(page).to have_no_text("Markdown source only.")
        expect(page).to have_content("Revision 4 content")
        expect(page).not_to have_content("Revision 2 content")
        expect(page).not_to have_content("Revision 3 content")
      end
      expect(page).to have_current_path(plan_history_page_path(plan, from: 2, to: 4))
      page.refresh
      expect(page).to have_select("From", selected: "v1")
      expect(page).to have_select("To", selected: "v4")
      expect(page).to have_css("#version-diff", text: "Revision 4 content")
    end

    it "changes either endpoint and only lists versions that could be selected" do
      visit plan_history_page_path(plan, from: 1, to: 4)
      select "v1", from: "From"
      expect(page).to have_select("To", options: [ "v4", "v3", "v2" ])
      select "v3", from: "To"
      expect(page).to have_select("From", options: [ "v2", "v1", "Empty document" ])
      expect(page).to have_current_path(plan_history_page_path(plan, from: 2, to: 3))
      expect(page).to have_css("#version-diff", text: "Revision 3 content")
      expect(page).to have_css(".history-split__item--active", count: 2)

      click_link "View v3", exact: true
      expect(page).to have_css("h1", text: "History Plan — v3")
      click_link "Back to history"
      expect(page).to have_current_path(plan_history_page_path(plan, from: 2, to: 3))
    end

    it "restores a changed range from Turbo's cache after browser Back" do
      visit plan_history_page_path(plan)
      select "v1", from: "From"
      expect(page).to have_css("#version-diff .del", text: "First task")

      click_link "View v4", exact: true
      expect(page).to have_css("h1", text: "History Plan — v4")
      page.execute_script(<<~JS)
        window.historyRestoreRequests = 0
        document.addEventListener("turbo:before-fetch-request", event => {
          const { pathname, searchParams } = event.detail.url
          if (pathname.endsWith("/history") && searchParams.get("from") === "2" && searchParams.get("to") === "4") {
            window.historyRestoreRequests++
          }
        })
      JS

      page.go_back
      expect(page).to have_current_path(plan_history_page_path(plan, from: 2, to: 4))
      expect(page).to have_select("From", selected: "v1")
      expect(page).to have_select("To", selected: "v4")
      expect(page).to have_css("#version-diff .del", text: "First task")
      expect(page.evaluate_script("window.historyRestoreRequests")).to eq(0)
    end

    it "opens a single revision with the keyboard and handles the empty baseline" do
      visit plan_history_page_path(plan)
      find("[data-revision='1'] .history-split__entry").send_keys(:enter)
      expect(page).to have_select("From", selected: "Empty document")
      expect(page).to have_select("To", selected: "v1")
      expect(page).to have_css("#version-diff", text: "Initial draft")
      expect(page).to have_css(".history-split__item--active", count: 1)
    end

    it "extends a row selection with Shift-click in the same tab" do
      visit plan_history_page_path(plan)
      find("[data-revision='2'] .history-split__entry").click
      find("[data-revision='4'] .history-split__entry").click(:shift)

      expect(page).to have_current_path(plan_history_page_path(plan, from: 2, to: 4))
      expect(page).to have_css(".history-split__item--active", count: 3)
      expect(page).to have_css("#version-diff", text: "Revision 4 content")
      expect(page.windows.size).to eq(1)
    end

    it "moves through rows with arrow keys and extends or shrinks the range with Shift" do
      visit plan_history_page_path(plan)
      find("body").send_keys(:arrow_down)
      expect(page).to have_css("[data-revision='3'] a:focus[aria-current='true']")
      expect(page).to have_select("From", selected: "v2")

      find("[data-revision='3'] a:focus").send_keys([ :shift, :arrow_down ])
      expect(page).to have_css("[data-revision='2'] a:focus")
      expect(page).to have_select("From", selected: "v1")
      expect(page).to have_select("To", selected: "v3")
      expect(page).to have_css(".history-split__item--active", count: 2)

      find("[data-revision='2'] a:focus").send_keys([ :shift, :arrow_up ])
      expect(page).to have_select("From", selected: "v2")
      expect(page).to have_select("To", selected: "v3")
      expect(page).to have_css(".history-split__item--active", count: 1)
    end

    it "keeps the selected range when a new version arrives live" do
      visit plan_history_page_path(plan, from: 2, to: 4)
      add_revision(5)

      expect(page).to have_select("To", selected: "v4", with_options: [ "v5" ], wait: 5)
      expect(page).to have_select("From", selected: "v1")
      expect(page).to have_css("#version-diff", text: "Revision 4 content")
      select "v5", from: "To"
      expect(page).to have_css("#version-diff", text: "Revision 5 content")
    end

    it "shows an in-place error and retries without losing the selected range" do
      visit plan_history_page_path(plan)
      page.execute_script <<~JS
        const original = window.fetch
        window.fetch = (...args) => {
          if (String(args[0]).includes('/diff')) {
            window.fetch = original
            return Promise.reject(new TypeError('Network unavailable'))
          }
          return original(...args)
        }
      JS
      select "v1", from: "From"

      expect(page).to have_content("Couldn't load this comparison. Try again.")
      expect(page).to have_no_css("#version-diff", visible: true)
      expect(page).to have_select("From", selected: "v1")
      click_button "Retry comparison"
      expect(page).to have_css("#version-diff .del", text: "First task")
      expect(page).to have_no_button("Retry comparison", visible: true)
    end

    it "keeps the newest selection when an older request completes later", browser_sync: :manual do
      visit plan_history_page_path(plan)
      page.execute_script <<~JS
        const original = window.fetch
        window.fetch = (...args) => {
          if (String(args[0]).includes('/diff')) {
            window.fetch = original
            // Let the real request finish, but hold its response until the
            // reader has chosen a different range.
            return original(...args).then(async response => {
              const body = await response.text()
              return new Promise(resolve => {
                window.releaseComparison = () => resolve(new Response(body, { status: response.status, headers: response.headers }))
                document.documentElement.dataset.comparisonHeld = 'true'
              })
            })
          }
          return original(...args)
        }
      JS
      select "v1", from: "From"
      expect(page).to have_content("Loading comparison…")
      expect(page).to have_no_css("#version-diff", visible: true)
      expect(page).to have_select("From", selected: "v1")
      expect(page).to have_css("html[data-comparison-held='true']")
      select "Empty document", from: "From"
      expect(page).to have_css("#version-diff .ins", text: "History Plan")
      page.evaluate_async_script("window.releaseComparison(); setTimeout(arguments[0], 0)")
      expect(page).to have_select("From", selected: "Empty document")
      expect(page).to have_css("#version-diff .ins", text: "History Plan")
    end
  end

  describe "who did it" do
    # The regression that prompted this: agent edits arrived in history
    # wearing the human's name alone, indistinguishable from their own
    # typing.
    it "names the agent that edited on the user's behalf" do
      Coplan::Plans::ReplaceContent.call(
        plan: plan,
        new_content: plan_content + "\nAgent addition.\n",
        base_revision: plan.current_revision,
        actor_type: "local_agent",
        actor_id: user.id,
        agent_name: "Claude",
        change_summary: "Agent follow-up"
      )

      visit plan_history_page_path(plan)

      expect(page).to have_content("Claude (via #{user.name})")
      # The human's own edit stays a plain name.
      expect(page).to have_content(user.name)
    end
  end

  def add_revision(revision, summary: "Edit #{revision}")
    Coplan::Plans::ReplaceContent.call(
      plan: plan.reload, new_content: "# History Plan\n\nRevision #{revision} content.\n",
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id,
      change_summary: summary
    )
  end
end
