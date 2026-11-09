require "rails_helper"

RSpec.describe "Comment cards in the margin", type: :system do
  let(:author) { create(:coplan_user, name: "Avery Author", email: "author@example.com") }
  let(:reviewer) { create(:coplan_user, name: "Riley Reviewer", email: "reviewer@example.com") }
  let(:long_body) do
    "This comment is long on purpose. " * 6 +
      "It covers the rollout order, the fallback plan, and the people who need to sign off before the change ships."
  end

  let(:plan_content) do
    <<~MARKDOWN
      Rollout notes for review.

      # Summary

      This plan replaces the nightly export with a streaming pipeline.

      #{(1..6).map { |n| "Background paragraph #{n} explains the current export and why it is slow.\n" }.join("\n")}

      The rollout touches the cache warmup and the retry budget in a single release.

      #{(1..4).map { |n| "Rollout paragraph #{n} lists one more step of the migration.\n" }.join("\n")}

      # Risks

      Backfills may overload the primary database during business hours.

      The old exporter stays available as a fallback for one week.
    MARKDOWN
  end

  let(:plan) { create_plan("Streaming Export Plan", plan_content) }

  def create_plan(title, content)
    created = CoPlan::Plan.create!(title: title, created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: created, revision: 1,
      content_markdown: content, actor_type: "human", actor_id: author.id
    )
    created.update!(current_plan_version: version, current_revision: 1)
    created
  end

  let!(:summary_thread) { create_anchored_thread(anchor_text: "streaming pipeline", body: "Which broker backs the stream?", user: reviewer) }
  let!(:warmup_thread) { create_anchored_thread(anchor_text: "cache warmup", body: "Warm the cache first.", user: reviewer) }
  let!(:budget_thread) { create_anchored_thread(anchor_text: "retry budget", body: "How many retries per request?", user: author) }
  let!(:long_thread) { create_anchored_thread(anchor_text: "overload the primary database", body: long_body, user: reviewer) }
  let!(:resolved_thread) do
    create_anchored_thread(anchor_text: "available as a fallback", body: "Is one week enough?", user: reviewer).tap { |thread| thread.resolve!(author) }
  end

  def create_anchored_thread(anchor_text:, body:, user:, on: plan)
    thread = on.comment_threads.create!(
      plan_version: on.current_plan_version, anchor_text: anchor_text, anchor_occurrence: 1,
      created_by_user: user, status: "open"
    )
    thread.comments.create!(author_type: "human", author_id: user.id, body_markdown: body)
    thread
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_no_current_path(sign_in_path)
    expect(page).to have_button("Menu")
  end

  def card_for(thread)
    find(".comment-margin__card[data-thread-id='comment_thread_#{thread.id}']")
  end

  def mark_for(thread)
    find("mark.anchor-highlight[data-thread-id='comment_thread_#{thread.id}']", match: :first)
  end

  # One round trip, so a scroll cannot land between two measurements.
  def rects(*elements)
    page.evaluate_script(<<~JS, *elements).map { |box| box.transform_keys(&:to_sym) }
      [...arguments].map(element => (r => ({ top: r.top, bottom: r.bottom, left: r.left, width: r.width }))(element.getClientRects()[0]))
    JS
  end

  def rect(element) = rects(element).first

  # Cards re-stack on the frame after a window opens, grows, or closes.
  def eventually(timeout: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    expect(yield).to be(true)
  end

  def choose_mode(label)
    within(".comment-margin-mode") { click_button label }
    expect(page).to have_css(".comment-margin-mode__option[aria-pressed='true']", text: label)
  end

  def show_cards(target = plan)
    visit plan_page_path(target)
    choose_mode "Cards"
    expect(page).to have_css(".comment-margin.comment-margin--cards[data-fits]")
  end

  before do
    page.current_window.resize_to(1760, 1000)
    sign_in(author)
  end

  after { page.current_window.resize_to(1400, 900) }

  it "shows each open discussion as a card aligned with its text, stacking close cards without overlap" do
    long_thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Only overnight.")
    long_thread.comments.create!(author_type: "human", author_id: reviewer.id, body_markdown: "Agreed.")
    show_cards

    # Resolved discussions stay hidden by default; document order is keyboard order.
    expect(page).to have_css(".comment-margin__card", count: 4)
    order = all(".comment-margin__card").map { |card| card[:"data-thread-id"] }
    expect(order).to eq([ summary_thread, warmup_thread, budget_thread, long_thread ].map { |thread| "comment_thread_#{thread.id}" })
    expect(page).to have_css("aside.comment-margin[aria-label='Discussions']")

    summary = card_for(summary_thread)
    within(summary) do
      expect(page).to have_css(".comment-margin__author", text: "Riley Reviewer")
      expect(page).to have_css(".comment-margin__time", text: "ago")
      expect(page).to have_css(".comment-margin__body", text: "Which broker backs the stream?")
      expect(page).to have_css(".comment-margin__status", text: "Open")
    end
    expect(summary.tag_name).to eq("button")
    expect(summary[:"aria-label"]).to be_nil
    expect(card_for(long_thread)).to have_css(".comment-margin__replies", text: "2 replies, latest from Riley Reviewer")
    # The long comment is clamped, with "more".
    expect(card_for(long_thread)[:class]).to include("is-truncated")
    expect(card_for(long_thread)).to have_css(".comment-margin__more", text: "more")
    expect(summary).to have_no_css(".comment-margin__more")

    # Cards sit in the margin beside the document, level with their text.
    document_right = find(".plan-document").evaluate_script("this.getBoundingClientRect().right")
    expect(rect(summary)[:left]).to be > document_right
    expect(rect(summary)[:top]).to be_within(2).of(rect(mark_for(summary_thread))[:top])
    expect(rect(card_for(warmup_thread))[:top]).to be_within(2).of(rect(mark_for(warmup_thread))[:top])

    # Two discussions on one line: the later card moves down below the first.
    warmup = rect(card_for(warmup_thread))
    budget = rect(card_for(budget_thread))
    expect(rect(mark_for(budget_thread))[:top]).to be_within(2).of(rect(mark_for(warmup_thread))[:top])
    expect(budget[:top]).to be >= warmup[:bottom]

    placed = all(".comment-margin__card").map { |card| rect(card) }.sort_by { |box| box[:top] }
    placed.each_cons(2) { |above, below| expect(below[:top]).to be >= above[:bottom] }

    # Show resolved brings back the resolved card, labelled as resolved.
    find("body").send_keys("s")
    expect(page).to have_css(".comment-margin__card", count: 5)
    expect(card_for(resolved_thread)[:class]).to include("comment-margin__card--resolved")
    expect(card_for(resolved_thread)).to have_css(".comment-margin__status", text: "Resolved")
  end

  it "opens the full discussion over the card when the card is clicked, and replies in place" do
    show_cards
    card = card_for(warmup_thread)
    card.click

    popover = find(".thread-popover.thread-popover--card:popover-open")
    expect(popover).to have_content("Warm the cache first.")
    window_box, card_box = rects(popover, card)
    expect(window_box[:left]).to be_within(1).of(card_box[:left])
    expect(window_box[:top]).to be_within(1).of(card_box[:top])
    expect(window_box[:width]).to be_within(1).of(card_box[:width])
    expect(card[:class]).to include("is-active")
    expect(card[:"aria-expanded"]).to eq("true")
    expect(page).to have_css("mark.is-margin-active[data-thread-id='comment_thread_#{warmup_thread.id}']")

    # The expanded card pushes the card below it down.
    eventually { below, window_box = rects(card_for(budget_thread), popover); below[:top] >= window_box[:bottom] }

    within(popover) do
      textarea = find("textarea[placeholder='Press r to reply']")
      textarea.fill_in with: "Warmup runs at deploy time."
      textarea.send_keys(:enter)
      expect(page).to have_content("Warmup runs at deploy time.")
    end
    expect(warmup_thread.comments.count).to eq(2)
    expect(card).to have_css(".comment-margin__replies", text: "1 reply, latest from Avery Author", visible: :all)
    # The card below moves further down as the discussion grows.
    expect(page).to have_css(".comment-margin__card[data-thread-id='comment_thread_#{budget_thread.id}']") { |below|
      below_box, window_box = rects(below, find(".thread-popover:popover-open"))
      below_box[:top] >= window_box[:bottom]
    }

    find("body").send_keys(:escape)
    expect(page).to have_no_css(".thread-popover:popover-open")
    expect(card[:class]).not_to include("is-active")
    expect(page).to have_no_css("mark.is-margin-active")
    eventually { below, above = rects(card_for(budget_thread), card); below[:top] >= above[:bottom] }
  end

  it "links a card and its highlight on hover, and clicking the highlight activates the card" do
    show_cards
    card = card_for(budget_thread)

    card.hover
    expect(page).to have_css("mark.is-margin-hover", count: 1, text: "retry budget")
    mark_for(summary_thread).hover
    expect(page).to have_css(".comment-margin__card.is-hover", count: 1)
    expect(card_for(summary_thread)[:class]).to include("is-hover")
    expect(page).to have_no_css("mark.is-margin-hover", text: "retry budget")

    mark_for(budget_thread).click
    expect(page).to have_css(".comment-margin__card.is-active[data-thread-id='comment_thread_#{budget_thread.id}']")
    popover = find(".thread-popover.thread-popover--card:popover-open")
    expect(popover).to have_content("How many retries per request?")
    # The active card lines up with its text again; the card above makes room.
    window_box, mark_box = rects(popover, mark_for(budget_thread))
    expect(window_box[:top]).to be <= mark_box[:top] + 2
    eventually do
      above, window_box = rects(card_for(warmup_thread), popover)
      above[:bottom] <= window_box[:top] || above[:top] >= window_box[:bottom]
    end
  end

  it "keeps the document still and other cards clear while an expanded discussion grows" do
    page.current_window.resize_to(1760, 640)
    show_cards
    mark = mark_for(budget_thread)
    page.execute_script("window.scrollTo(0, Math.max(0, arguments[0].getBoundingClientRect().top + scrollY - innerHeight + 150))", mark)
    scroll = page.evaluate_script("scrollY")
    mark.click
    popover = find(".thread-popover.thread-popover--card:popover-open")
    clear_and_on_screen = lambda do
      box = rect(popover)
      cards = all(".comment-margin__card:not(.is-active)").map { |card| rect(card) }
      box[:bottom] <= page.evaluate_script("innerHeight - 11") &&
        cards.all? { |card| card[:bottom] <= box[:top] || card[:top] >= box[:bottom] }
    end
    eventually(&clear_and_on_screen)
    expect(page.evaluate_script("scrollY")).to eq(scroll)

    textarea = popover.find("textarea[placeholder='Press r to reply']")
    textarea.click
    6.times { |n| textarea.send_keys("Draft line #{n + 1}", [ :shift, :enter ]) }
    eventually(&clear_and_on_screen)
    expect(page.evaluate_script("scrollY")).to eq(scroll)

    textarea.send_keys("Ready to send.", :enter)
    expect(popover).to have_content("Ready to send.")
    eventually(&clear_and_on_screen)
    expect(page.evaluate_script("scrollY")).to eq(scroll)
  end

  it "activates the matching card with j and k" do
    show_cards
    find("body").send_keys("j")
    expect(page).to have_css(".comment-margin__card.is-active[data-thread-id='comment_thread_#{summary_thread.id}']")
    expect(page).to have_css(".thread-popover.thread-popover--card:popover-open", text: "Which broker backs the stream?")

    find("body").send_keys("j")
    expect(page).to have_css(".comment-margin__card.is-active[data-thread-id='comment_thread_#{warmup_thread.id}']")
    expect(page).to have_css(".comment-margin__card.is-active", count: 1)
    popover = find(".thread-popover.thread-popover--card:popover-open", text: "Warm the cache first.")
    expect(rect(popover)[:left]).to be_within(1).of(rect(card_for(warmup_thread))[:left])

    find("body").send_keys("k")
    expect(page).to have_css(".comment-margin__card.is-active[data-thread-id='comment_thread_#{summary_thread.id}']")
  end

  it "activates the card for a ?thread= link" do
    show_cards
    visit plan_page_path(plan, thread: long_thread.id)

    expect(page).to have_css(".comment-margin__card.is-active[data-thread-id='comment_thread_#{long_thread.id}']")
    popover = find(".thread-popover.thread-popover--card:popover-open")
    expect(popover).to have_content("This comment is long on purpose.")
    expect(rect(popover)[:left]).to be_within(1).of(rect(card_for(long_thread))[:left])
  end

  it "switches between markers and cards and remembers the choice" do
    visit plan_page_path(plan)
    # Markers are the default.
    expect(page).to have_css(".comment-margin__card", count: 4)
    expect(page).to have_no_css(".comment-margin--cards")
    expect(page).to have_css(".comment-margin-mode__option[data-mode='markers'][aria-pressed='true']")
    expect(card_for(summary_thread)[:"aria-label"]).to eq("Discussion started by Riley Reviewer")

    choose_mode "Cards"
    expect(page).to have_css(".comment-margin--cards .comment-margin__card", count: 4)
    expect(page.evaluate_script("localStorage.getItem('coplan:comment-margin:#{author.id}')")).to eq("cards")

    visit plan_page_path(plan)
    expect(page).to have_css(".comment-margin--cards .comment-margin__card", count: 4)
    expect(page).to have_css(".comment-margin-mode__option[data-mode='cards'][aria-pressed='true']")

    choose_mode "Markers"
    expect(page).to have_no_css(".comment-margin--cards")
    expect(card_for(summary_thread)[:"aria-label"]).to eq("Discussion started by Riley Reviewer")
    expect(rect(card_for(summary_thread))[:width]).to be_within(1).of(30)

    visit plan_page_path(plan)
    expect(page).to have_css(".comment-margin[data-fits] .comment-margin__card", count: 4)
    expect(page).to have_no_css(".comment-margin--cards")
    expect(page).to have_css(".comment-margin-mode__option[data-mode='markers'][aria-pressed='true']")
  end

  it "falls back to markers when the window is too narrow for cards" do
    show_cards

    page.current_window.resize_to(1400, 900)
    expect(page).to have_no_css(".comment-margin--cards")
    expect(page).to have_css(".comment-margin[data-fits] .comment-margin__card", count: 4)
    expect(card_for(summary_thread)[:"aria-label"]).to eq("Discussion started by Riley Reviewer")
    expect(rect(card_for(summary_thread))[:width]).to be_within(1).of(30)
    # The choice is kept, and the switch explains why markers are showing.
    expect(page).to have_css(".comment-margin-mode[data-fallback]")
    expect(find(".comment-margin-mode__option[data-mode='cards'][aria-pressed='true']")[:title]).to include("wider window")

    page.current_window.resize_to(1760, 1000)
    expect(page).to have_css(".comment-margin--cards .comment-margin__card", count: 4)
    expect(page).to have_no_css(".comment-margin-mode[data-fallback]")
  end

  it "hides the mode switch when even markers cannot fit" do
    show_cards
    page.current_window.resize_to(1201, 900)
    expect(page).to have_no_css(".comment-margin[data-fits]")
    expect(page).to have_no_css(".comment-margin-mode")

    page.current_window.resize_to(1760, 1000)
    expect(page).to have_css(".comment-margin-mode")
    expect(page).to have_css(".comment-margin--cards")
  end

  it "keeps the masthead steady when a collapsed-only discussion becomes a card" do
    sectioned = create_plan("Collapsed appendix", <<~MARKDOWN)
      <details>
      <summary>Evidence</summary>

      The queue backed up during rollout.

      </details>
    MARKDOWN
    create_anchored_thread(anchor_text: "queue backed up", body: "How deep?", user: reviewer, on: sectioned)
    show_cards
    visit plan_page_path(sectioned)
    badge = find(".details-comment-badge")
    expect(page).to have_no_css(".comment-margin-mode")
    toolbar = find("[role='toolbar'][aria-label='Plan actions']")
    before = rect(toolbar)

    badge.click
    expect(page).to have_css(".comment-margin-mode")
    expect(page).to have_css(".comment-margin__card.is-active")
    expect(rect(toolbar)[:left]).to be_within(1).of(before[:left])
  end

  it "updates cards from comment and thread broadcasts without a reload" do
    show_cards
    card = card_for(summary_thread)
    expect(card).to have_no_css(".comment-margin__replies", text: "reply")

    reply = summary_thread.comments.create!(author_type: "human", author_id: reviewer.id, body_markdown: "Probably the managed broker.")
    CoPlan::Broadcaster.append_to(plan, target: "comments_comment_thread_#{summary_thread.id}",
      partial: "coplan/comments/comment", locals: { comment: reply })
    expect(card).to have_css(".comment-margin__replies", text: "1 reply, latest from Riley Reviewer")

    arriving = create_anchored_thread(anchor_text: "nightly export", body: "Keep the nightly export for audits.", user: reviewer)
    CoPlan::Broadcaster.append_to(plan, target: "plan-threads",
      partial: "coplan/comment_threads/thread_popover", locals: { thread: arriving, plan: plan })
    expect(page).to have_css(".comment-margin__card", count: 5)
    expect(card_for(arriving)).to have_css(".comment-margin__body", text: "Keep the nightly export for audits.")
    expect(rect(card_for(arriving))[:top]).to be_within(2).of(rect(mark_for(arriving))[:top])
  end

  it "hides the card of a slide passage scrolled out of its slide" do
    deck = create_plan("Rollout deck", <<~MARKDOWN)
      ::: {.presentation}

      # First slide

      First discussion target.

      ---

      # Second slide

      Second discussion target.

      #{(1..35).map { |n| "Paragraph #{n} keeps this slide scrollable.\n" }.join("\n")}

      :::
    MARKDOWN
    thread = create_anchored_thread(anchor_text: "Second discussion target", body: "Scrolling feedback", user: reviewer, on: deck)
    visit plan_page_path(deck)
    find(".deck-toolbar__step--next").click
    choose_mode "Cards"
    expect(page).to have_css(".comment-margin.comment-margin--cards[data-fits]")
    card = card_for(thread)
    expect(rect(card)[:top]).to be_within(2).of(rect(mark_for(thread))[:top])

    find(".deck-slide--current").execute_script("this.scrollTop = this.scrollHeight")
    expect(page).to have_css(".comment-margin--cards .comment-margin__card[hidden]", visible: :all)
    # The cards-mode layout must not override [hidden] and leave the card
    # stranded at the top of the margin.
    expect(card.evaluate_script("getComputedStyle(this).display")).to eq("none")
    expect(page).to have_no_css(".comment-margin__card")

    find(".deck-slide--current").execute_script("this.scrollTop = 0")
    expect(page).to have_css(".comment-margin--cards .comment-margin__card[data-thread-id='comment_thread_#{thread.id}']")
    eventually { card_box, mark_box = rects(card_for(thread), mark_for(thread)); (card_box[:top] - mark_box[:top]).abs < 2 }
  end

  it "keeps an expanded card's reply box and Resolve on screen near the end of a short page, as it grows" do
    short = create_plan("Short rollout note", <<~MARKDOWN)
      #{(1..5).map { |n| "Step #{n} prepares the rollout.\n" }.join("\n")}

      The final step flips the feature flag for everyone.
    MARKDOWN
    thread = create_anchored_thread(anchor_text: "flips the feature flag", body: "Who watches the dashboards?", user: reviewer, on: short)
    2.times { |n| thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Reply #{n + 1}: the on-call engineer.") }
    page.current_window.resize_to(1760, 640)
    show_cards(short)
    # Scroll as far as the page goes, so scrolling cannot make room.
    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
    card_for(thread).click

    popover = find(".thread-popover.thread-popover--card:popover-open")
    on_screen = lambda do
      textarea = popover.find("textarea[placeholder='Press r to reply']")
      resolve = popover.find_button("Resolve")
      window_box, textarea_box, resolve_box = rects(popover, textarea, resolve)
      viewport = page.evaluate_script("window.innerHeight")
      [ textarea_box, resolve_box ].all? { |box| box[:top] >= 0 && box[:bottom] <= viewport } &&
        window_box[:bottom] <= viewport - 11 && window_box[:top] >= 0
    end
    eventually(&on_screen)

    # A longer draft grows the window; it stays on screen.
    textarea = popover.find("textarea[placeholder='Press r to reply']")
    textarea.click
    4.times { |n| textarea.send_keys("Draft line #{n + 1}", [ :shift, :enter ]) }
    eventually(&on_screen)

    # So does a posted reply.
    textarea.send_keys("Posted at the end.", :enter)
    expect(popover).to have_content("Posted at the end.")
    eventually(&on_screen)
  end

  it "shows a closed section's badge instead of cards, and its badge opens the section at an active card" do
    sectioned = create_plan("Queue incident review", <<~MARKDOWN)
      Summary: the retry budget ran out during the deploy.

      <details id="raw-timeline">
      <summary>Raw timeline</summary>

      The queue backed up right after the rollout started.

      </details>

      Alert on queue age before the next rollout.
    MARKDOWN
    outside = create_anchored_thread(anchor_text: "retry budget", body: "Is the budget per partner?", user: reviewer, on: sectioned)
    inside = create_anchored_thread(anchor_text: "queue backed up", body: "How deep did the queue get?", user: reviewer, on: sectioned)
    show_cards(sectioned)

    expect(page).to have_css(".comment-margin__card", count: 1)
    expect(card_for(outside)).to have_css(".comment-margin__body", text: "Is the budget per partner?")
    expect(page).to have_no_css(".comment-margin__card[data-thread-id='comment_thread_#{inside.id}']", visible: :all)
    badge = find("#raw-timeline:not([open]) > summary .details-comment-badge")
    expect(badge[:"data-count"]).to eq("1")

    badge.click
    expect(page).to have_css("#raw-timeline[open]")
    expect(page).to have_no_css(".details-comment-badge")
    expect(page).to have_css(".comment-margin__card.is-active[data-thread-id='comment_thread_#{inside.id}']")
    expect(page).to have_css(".comment-margin__card", count: 2)
    popover = find(".thread-popover.thread-popover--card:popover-open", text: "How deep did the queue get?")
    eventually { window_box, card_box = rects(popover, card_for(inside)); (window_box[:left] - card_box[:left]).abs < 1 }
  end
end
