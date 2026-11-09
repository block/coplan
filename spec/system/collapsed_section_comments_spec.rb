require "rails_helper"

RSpec.describe "Discussions inside collapsed sections", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }
  let(:reviewer) { create(:coplan_user, email: "reviewer@example.com") }

  let(:plan) do
    plan = CoPlan::Plan.create!(title: "Queue incident review", created_by_user: author)
    version = CoPlan::PlanVersion.create!(plan: plan, revision: 1, actor_type: "human", actor_id: author.id,
      content_markdown: <<~MARKDOWN)
        Summary: the retry budget ran out during the deploy.

        <details id="raw-timeline">
        <summary>Raw timeline</summary>

        The queue backed up right after the rollout started.

        Workers recovered once the cache warmed.

        A manual drain was considered and rejected.

        <details>
        <summary>Queue samples</summary>

        | Status | Count |
        | --- | --- |
        | Waiting | 42 |

        </details>

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

  def section = find("#raw-timeline")
  def badge = section.find("summary .details-comment-badge")
  def collapsed = "#raw-timeline:not([open])"
  def expanded = "#raw-timeline[open]"

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(library_page_path(author))
    page.current_window.resize_to(1600, 900)
  end

  after { page.current_window.resize_to(1400, 900) }

  def table_discussion
    _, start, finish = CoPlan::Plans::SourceTargets.new(plan.current_content).ranges.find { |kind, *| kind == "table_cell" }
    token = CoPlan::Plans::SourceTargets.verifier.generate(
      { "digest" => Digest::SHA256.hexdigest(plan.current_content), "kind" => "table_cell",
        "start" => start, "end" => finish, "label" => "Status" }, purpose: "comment")
    thread = plan.comment_threads.create!(plan_version: plan.current_plan_version, source_token: token,
      created_by_user: reviewer, status: "open")
    thread.comments.create!(author_type: "human", author_id: reviewer.id, body_markdown: "How old are these samples?")

    thread
  end

  it "reveals every enclosing section for a linked table discussion" do
    thread = table_discussion
    visit plan_page_path(plan, thread: thread.id)
    expect(page).to have_css(".source-comments:popover-open", text: "How old are these samples?")
    expect(page).to have_css("#plan-content-body details[open]", count: 2)
    expect(page).to have_css(".data-grid .source-thread-badge", visible: true)
    expect(page).to have_no_css(".source-comments textarea:focus")
  end

  it "returns focus to the table cell after its discussion closes" do
    table_discussion
    visit plan_page_path(plan)
    section.find("summary", text: "Raw timeline").click
    nested = section.find("details")
    nested.find(".details-comment-badge").send_keys(:enter)
    expect(page).to have_css(".source-comments:popover-open", text: "How old are these samples?")
    expect(nested).to have_no_css(".details-comment-badge", visible: :all)
    expect(page).to have_css(".source-comments [aria-label='Close element comments']:focus")
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_css("[data-source-target]:focus", text: "Status")
  end

  it "ignores a source badge whose thread disappeared before activation" do
    thread = table_discussion
    visit plan_page_path(plan)
    section.find("summary", text: "Raw timeline").click
    source_badge = section.find("details").find(".details-comment-badge")
    # Model a Turbo replacement in the interval before the margin refresh.
    dispatched_ids = source_badge.evaluate_script(<<~JS, "comment_thread_#{thread.id}")
      ((button, id) => {
        const dispatched = [];
        const observe = event => { dispatched.push(event.detail.threadId ?? null); };
        document.addEventListener("coplan:source-thread", observe);
        button.click(); // Prove the action is bound and the event is observable.
        document.getElementById(id).remove();
        button.click();
        document.removeEventListener("coplan:source-thread", observe);
        return dispatched;
      })(this, arguments[0])
    JS
    expect(dispatched_ids).to eq([ thread.id ])
  end

  it "keeps keyboard focus on the summary after activating its discussion badge" do
    visit plan_page_path(plan)
    badge.send_keys(:enter)
    expect(page).to have_css("#comment_thread_#{backlog.id}_popover:popover-open")
    expect(section).to have_no_css(".details-comment-badge", visible: :all)
    expect(page).to have_css("#raw-timeline > summary:focus")
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_no_css(".thread-popover:popover-open")
    expect(page).to have_css("#raw-timeline > summary:focus")
  end

  it "marks a newly revealed margin card active and clears it when dismissed" do
    visit plan_page_path(plan)
    badge.click
    expect(page).to have_css("#comment_thread_#{backlog.id}_popover:popover-open")
    expect(page).to have_css(".comment-margin__card.is-active[data-thread-id='comment_thread_#{backlog.id}']")
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_no_css(".comment-margin__card.is-active")
  end

  it "offers a discussion button target at least 24 pixels in each dimension" do
    visit plan_page_path(plan)
    expect(badge.rect.width).to be >= 24
    expect(badge.rect.height).to be >= 24
  end

  it "counts open discussions on the collapsed summary and opens the first one" do
    visit plan_page_path(plan)
    expect(page).to have_css(collapsed)
    expect(badge["data-count"]).to eq("2")
    expect(badge[:"aria-label"]).to eq("2 discussions in this section, open the first")

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

  it "counts and stacks two discussions on the same line of a collapsed section" do
    same_line = discuss("rollout started", "Which rollout step was this?")
    visit plan_page_path(plan)
    expect(badge["data-count"]).to eq("3")

    section.find("summary", text: "Raw timeline").click
    first = find(".comment-margin__card[data-thread-id='comment_thread_#{backlog.id}']")
    second = find(".comment-margin__card[data-thread-id='comment_thread_#{same_line.id}']")
    rect = ->(element) { element.evaluate_script("(r => ({top: r.top, bottom: r.bottom}))(this.getBoundingClientRect())") }
    upper, lower = [ rect.(first), rect.(second) ].sort_by { |r| r["top"] }
    expect(lower["top"]).to be >= upper["bottom"]

    find("body").send_keys(:escape)
    find("body").send_keys("j")
    find("body").send_keys("j")
    expect(page).to have_css("#comment_thread_#{backlog.id}_popover:popover-open")
    find("body").send_keys("j")
    expect(page).to have_css("#comment_thread_#{same_line.id}_popover:popover-open")
  end
end
