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

      # A full page: version entry, plan title, no document body.
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
      expect(page).to have_css("#history-count", text: "2 entries")
    end

    it "shows a new version created while the history page is open" do
      # Create v2 after opening history — the broadcast prepends it live.
      visit plan_history_page_path(plan)

      expect(page).to have_css("#history-count", text: "1")
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
    end
  end

  describe "inline diff preview" do
    it "auto-loads the latest version's diff in the detail pane" do
      visit plan_history_page_path(plan)

      expect(page).to have_css("#version-diff")
      expect(page).to have_link("View full version →")
      expect(current_path).to eq(plan_history_page_path(plan))
    end
  end

  describe "contiguous revision selection" do
    before do
      (2..4).each { |revision| add_revision(revision) }
    end

    it "fills gaps, compares net changes, and restores the range after reloading" do
      visit plan_history_page_path(plan)
      expect(page).to have_checked_field("Include changes in v4")
      check "Include changes in v2"

      expect(page).to have_checked_field("Include changes in v2")
      expect(page).to have_checked_field("Include changes in v3")
      expect(page).to have_checked_field("Include changes in v4")
      within("#version-diff") do
        expect(page).to have_content("v1 → v4")
        expect(page).to have_content("Revision 4 content")
        expect(page).not_to have_content("Revision 2 content")
        expect(page).not_to have_content("Revision 3 content")
      end
      expect(page).to have_current_path(plan_history_page_path(plan, from: 2, to: 4))
      page.refresh
      expect(page).to have_checked_field("Include changes in v2")
      expect(page).to have_checked_field("Include changes in v3")
      expect(page).to have_css("#version-diff", text: "v1 → v4")
    end

    it "shrinks either end and keeps a continuous newer range when unchecking inside" do
      visit plan_history_page_path(plan, from: 1, to: 4)
      uncheck "Include changes in v1"
      expect(page).to have_css("#version-diff", text: "v1 → v4")
      uncheck "Include changes in v4"
      expect(page).to have_css("#version-diff", text: "v1 → v3")
      check "Include changes in v1"
      expect(page).to have_css("#version-diff", text: "Empty document → v3")
      uncheck "Include changes in v2"

      expect(page).to have_unchecked_field("Include changes in v1")
      expect(page).to have_unchecked_field("Include changes in v2")
      expect(page).to have_checked_field("Include changes in v3")
      expect(page).to have_unchecked_field("Include changes in v4")
      expect(page).to have_css("#version-diff", text: "v2 → v3")
    end

    it "starts a fresh range after clearing and supports keyboard selection" do
      visit plan_history_page_path(plan)
      click_button "Clear selection"
      expect(page).to have_content("Select a revision to see its changes")
      expect(page).to have_no_css("#version-diff", visible: true)

      find_field("Include changes in v2").send_keys(:space)
      expect(page).to have_css("#version-diff", text: "v1 → v2")
      find_field("Include changes in v3").send_keys(:space)
      expect(page).to have_css("#version-diff", text: "v1 → v3")
      find("[data-revision='1'] .history-split__entry").click
      expect(page).to have_css("#version-diff", text: "Empty document → v1")
      expect(page).to have_unchecked_field("Include changes in v2")
      uncheck "Include changes in v1"
      expect(page).to have_content("Select a revision to see its changes")
    end

    it "keeps the selected range when a new version arrives live" do
      visit plan_history_page_path(plan, from: 2, to: 4)
      add_revision(5)

      expect(page).to have_unchecked_field("Include changes in v5", wait: 5)
      expect(page).to have_checked_field("Include changes in v2")
      expect(page).to have_checked_field("Include changes in v4")
      expect(page).to have_css("#version-diff", text: "v1 → v4")
      check "Include changes in v5"
      expect(page).to have_css("#version-diff", text: "v1 → v5")
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
      check "Include changes in v2"

      expect(page).to have_content("Couldn't load this comparison. Try again.")
      expect(page).to have_no_css("#version-diff", visible: true)
      expect(page).to have_checked_field("Include changes in v3")
      click_button "Retry comparison"
      expect(page).to have_css("#version-diff", text: "v1 → v4")
      expect(page).to have_no_button("Retry comparison", visible: true)
    end

    it "keeps the newest selection when an older request completes later" do
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
      check "Include changes in v2"
      expect(page).to have_content("Loading comparison…")
      expect(page).to have_no_css("#version-diff", visible: true)
      expect(page).to have_checked_field("Include changes in v3")
      expect(page).to have_css("html[data-comparison-held='true']")
      check "Include changes in v1"
      expect(page).to have_css("#version-diff", text: "Empty document → v4")
      page.evaluate_async_script("window.releaseComparison(); setTimeout(arguments[0], 0)")
      expect(page).to have_checked_field("Include changes in v1")
      expect(page).to have_css("#version-diff", text: "Empty document → v4")
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

  def add_revision(revision)
    CoPlan::Plans::ReplaceContent.call(
      plan: plan.reload, new_content: "# History Plan\n\nRevision #{revision} content.\n",
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id,
      change_summary: "Edit #{revision}"
    )
  end
end
