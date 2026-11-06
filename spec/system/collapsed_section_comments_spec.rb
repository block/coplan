require "rails_helper"

RSpec.describe "Discussions inside collapsed sections", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }
  let(:reviewer) { create(:coplan_user, email: "reviewer@example.com") }

  let(:plan) do
    plan = CoPlan::Plan.create!(title: "Queue incident review", created_by_user: author)
    version = CoPlan::PlanVersion.create!(plan: plan, revision: 1, actor_type: "human", actor_id: author.id,
      content_markdown: <<~MARKDOWN)
        Summary: the retry budget ran out during the deploy.

        <details>
        <summary>Raw timeline</summary>

        The queue backed up right after the rollout started.

        Workers recovered once the cache warmed.

        A manual drain was considered and rejected.

        </details>

        ## Follow-ups

        Alert on queue age before the next rollout.
      MARKDOWN
    plan.update!(current_plan_version: version, current_revision: 1)
    plan
  end

  let!(:outside) { discuss("retry budget", "Is the budget per partner?") }
  let!(:backlog) { discuss("queue backed up", "How deep did the queue get?") }
  let!(:recovery) { discuss("cache warmed", "Can we warm the cache before rollout?") }
  let!(:drain) { discuss("manual drain", "Why was the drain rejected?").tap { |thread| thread.resolve!(author) } }

  def discuss(anchor, body)
    thread = plan.comment_threads.create!(plan_version: plan.current_plan_version, anchor_text: anchor,
      anchor_occurrence: 1, created_by_user: reviewer, status: "open")
    thread.comments.create!(author_type: "human", author_id: reviewer.id, body_markdown: body)
    thread
  end

  def section = find("#plan-content-body details")
  def badge = section.find("summary .details-comment-badge")
  def collapsed = "#plan-content-body details:not([open])"
  def expanded = "#plan-content-body details[open]"

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(library_page_path(author))
    page.current_window.resize_to(1600, 900)
  end

  after { page.current_window.resize_to(1400, 900) }

  it "counts open discussions on the collapsed summary and opens the first one" do
    visit plan_page_path(plan)
    expect(page).to have_css(collapsed)
    expect(badge["data-count"]).to eq("2")
    expect(badge[:"aria-label"]).to eq("2 discussions in this section")

    # Resolved discussions count only while they are shown.
    find("body").send_keys("s")
    expect(section).to have_css(".details-comment-badge[data-count='3']")
    find("body").send_keys("s")
    expect(section).to have_css(".details-comment-badge[data-count='2']")

    badge.click
    expect(page).to have_css(expanded)
    expect(page).to have_css("#comment_thread_#{backlog.id}_popover:popover-open", text: "How deep did the queue get?")
    expect(section).to have_no_css(".details-comment-badge", visible: :all)
    mark = find("mark[data-thread-id='comment_thread_#{backlog.id}']")
    expect(mark.evaluate_script("this.getClientRects().length")).to be > 0
  end

  it "opens the section for a linked discussion" do
    visit plan_page_path(plan, thread: recovery.id)
    expect(page).to have_css("#comment_thread_#{recovery.id}_popover:popover-open", text: "Can we warm the cache before rollout?")
    expect(page).to have_css(expanded)
    expect(find("mark[data-thread-id='comment_thread_#{recovery.id}']")).to be_visible
  end

  it "reaches discussions in a collapsed section with j and k" do
    visit plan_page_path(plan)
    expect(badge["data-count"]).to eq("2")

    find("body").send_keys("j")
    expect(page).to have_css("#comment_thread_#{outside.id}_popover:popover-open")
    expect(page).to have_css(collapsed)

    find("body").send_keys("j")
    expect(page).to have_css("#comment_thread_#{backlog.id}_popover:popover-open", text: "How deep did the queue get?")
    expect(page).to have_css(expanded)
    expect(find("mark[data-thread-id='comment_thread_#{backlog.id}']")).to be_visible

    # k from the first discussion wraps to the last one, inside the section.
    section.find("summary", text: "Raw timeline").click
    expect(page).to have_css(collapsed)
    find("body").send_keys(:escape)
    find("body").send_keys("k")
    find("body").send_keys("k")
    expect(page).to have_css("#comment_thread_#{recovery.id}_popover:popover-open")
    expect(page).to have_css(expanded)
  end

  it "adds and removes margin markers as the section opens and closes" do
    visit plan_page_path(plan)
    expect(page).to have_css(".comment-margin__card[data-thread-id='comment_thread_#{outside.id}']")
    expect(page).to have_no_css(".comment-margin__card[data-thread-id='comment_thread_#{backlog.id}']")

    section.find("summary", text: "Raw timeline").click
    expect(page).to have_css(".comment-margin__card[data-thread-id='comment_thread_#{backlog.id}']")
    expect(page).to have_css(".comment-margin__card[data-thread-id='comment_thread_#{recovery.id}']")
    card = find(".comment-margin__card[data-thread-id='comment_thread_#{backlog.id}']")
    middle = ->(element) { element.evaluate_script("(r => r.top + r.height / 2)(this.getClientRects()[0])") }
    expect(middle.(card)).to be_within(4).of(middle.(find("mark[data-thread-id='comment_thread_#{backlog.id}']")))
    expect(section).to have_no_css(".details-comment-badge", visible: :all)

    section.find("summary", text: "Raw timeline").click
    expect(page).to have_no_css(".comment-margin__card[data-thread-id='comment_thread_#{backlog.id}']")
    expect(section).to have_css(".details-comment-badge[data-count='2']")
  end
end
