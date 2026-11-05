require "rails_helper"

RSpec.describe "Comment reactions", type: :system do
  let(:viewer) { create(:coplan_user, email: "reactions-viewer@example.com", name: "Hampton") }
  let(:sam) { create(:coplan_user, email: "reactions-sam@example.com", name: "Sam Chen") }
  let(:content) do
    <<~MARKDOWN
      # Reaction plan

      The cache keeps results warm between deploys.

      | Name | Status |
      |---|---|
      | Receipt | queued |
    MARKDOWN
  end
  let(:plan) do
    CoPlan::Plan.create!(title: "Reaction plan", created_by_user: viewer).tap do |p|
      version = create(:plan_version, plan: p, revision: 1, content_markdown: content)
      p.update!(current_plan_version: version, current_revision: 1)
    end
  end
  let!(:thread_record) do
    plan.comment_threads.create!(plan_version: plan.current_plan_version, anchor_text: "keeps results warm",
      anchor_occurrence: 1, created_by_user: sam, status: "open")
  end
  let!(:comment) do
    thread_record.comments.create!(author_type: "human", author_id: sam.id, body_markdown: "How long do results stay warm?")
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_no_current_path(sign_in_path)
    expect(page).to have_button("Menu")
  end

  def open_thread
    visit plan_page_path(plan)
    find("mark[data-thread-id='comment_thread_#{thread_record.id}']").click
    find(".thread-popover:popover-open")
  end

  def wait_for(timeout: Capybara.default_max_wait_time)
    Timeout.timeout(timeout) { sleep 0.05 until yield }
  end

  def have_reaction(kind, count:, pressed:)
    have_css(".comment-reaction[data-kind='#{kind}'][aria-pressed='#{pressed}'] .comment-reaction__count", exact_text: count.to_s)
  end

  # A click can be lost while the server's copy replaces the chips (the
  # press and release land on different elements), so wait for that copy.
  def have_saved_reactions
    have_css(".comment-reactions[data-version='#{comment.reload.reactions_version}']")
  end

  def chip(scope, emoji)
    scope.find(".comment-reaction", text: emoji)
  end

  def create_table_thread
    _, start, finish = CoPlan::Plans::SourceTargets.new(plan.current_content).ranges.find { |kind, *| kind == "table_cell" }
    token = CoPlan::Plans::SourceTargets.verifier.generate(
      { "digest" => Digest::SHA256.hexdigest(plan.current_content), "kind" => "table_cell",
        "start" => start, "end" => finish, "label" => "Status" }, purpose: "comment")
    plan.comment_threads.create!(plan_version: plan.current_plan_version, source_token: token,
      created_by_user: sam, status: "open").tap do |table_thread|
      table_thread.comments.create!(author_type: "human", author_id: sam.id, body_markdown: "Queued for how long?")
    end
  end

  def open_table_discussion
    visit plan_page_path(plan)
    find(".data-grid .source-thread-badge").click
    find(".source-comments", visible: true).tap { |panel| expect(panel).to have_text("Queued for how long?") }
  end

  before { sign_in(viewer) }

  it "marks the viewer's own reactions as pressed and names who reacted" do
    create(:comment_reaction, comment: comment, user: viewer, kind: "thumbs_up")
    create(:comment_reaction, comment: comment, user: sam, kind: "thumbs_up")
    create(:comment_reaction, comment: comment, user: sam, kind: "tada")

    popover = open_thread

    expect(popover).to have_css(".comment-reaction[aria-pressed='true']", text: "👍")
    expect(popover).to have_css(".comment-reaction[aria-pressed='false']", text: "🎉")
    expect(chip(popover, "👍")[:"aria-label"]).to eq("You, Sam Chen reacted with thumbs up")
    expect(chip(popover, "🎉")[:"aria-label"]).to eq("Sam Chen reacted with party popper")

    chip(popover, "🎉").hover
    expect(page).to have_css(".comment-reactions__tooltip:popover-open[data-text='Sam Chen reacted with 🎉']", visible: :all)
    chip(popover, "👍").hover
    expect(page).to have_css(".comment-reactions__tooltip:popover-open[data-text='You, Sam Chen reacted with 👍']", visible: :all)
  end

  it "adds and removes reactions in place without reloading" do
    create(:comment_reaction, comment: comment, user: sam, kind: "tada")
    popover = open_thread
    page.execute_script("window.reactionsPageMarker = true")

    popover.find(".comment-reactions__add").click
    expect(page).to have_css(".comment-reactions__picker:popover-open")
    find(".comment-reactions__picker:popover-open .comment-reactions__option", text: "🚀").click

    expect(popover).to have_reaction("rocket", count: 1, pressed: true)
    expect(page).to have_no_css(".comment-reactions__picker:popover-open")
    wait_for { comment.reactions.where(user: viewer, kind: "rocket").exists? }
    expect(popover).to have_saved_reactions

    chip(popover, "🎉").click
    expect(popover).to have_reaction("tada", count: 2, pressed: true)
    wait_for { comment.reactions.where(kind: "tada").count == 2 }
    expect(popover).to have_saved_reactions

    chip(popover, "🎉").click
    expect(popover).to have_reaction("tada", count: 1, pressed: false)
    chip(popover, "🚀").click
    expect(popover).to have_no_css(".comment-reaction", text: "🚀")
    wait_for { comment.reactions.where(user: viewer).count == 0 }

    expect(page).to have_css(".thread-popover:popover-open")
    expect(page.evaluate_script("window.reactionsPageMarker")).to be(true)
  end

  it "shows another person's reaction live" do
    popover = open_thread

    reaction = create(:comment_reaction, comment: comment, user: sam, kind: "eyes")
    comment.bump_reactions_version!
    CoPlan::Broadcaster.replace_to(plan, target: ActionView::RecordIdentifier.dom_id(comment, :reactions),
      partial: "coplan/comments/reactions", locals: { comment: reaction.comment.reload })

    expect(popover).to have_reaction("eyes", count: 1, pressed: false)
  end

  it "closes the picker when the comment window scrolls" do
    popover = open_thread
    popover.find(".comment-reactions__add").click
    expect(page).to have_css(".comment-reactions__picker:popover-open")

    page.execute_script("document.querySelector('.thread-popover:popover-open .thread-popover__comments').dispatchEvent(new Event('scroll'))")

    expect(page).to have_no_css(".comment-reactions__picker:popover-open")
    expect(page).to have_css(".thread-popover:popover-open")
  end

  it "ignores a replacement older than the chips on screen" do
    popover = open_thread
    target = ActionView::RecordIdentifier.dom_id(comment, :reactions)
    stale = CoPlan::ApplicationController.render(partial: "coplan/comments/reactions", locals: { comment: comment })
    create(:comment_reaction, comment: comment, user: sam, kind: "eyes")
    comment.bump_reactions_version!
    CoPlan::Broadcaster.replace_to(plan, target: target, partial: "coplan/comments/reactions", locals: { comment: comment.reload })
    expect(popover).to have_reaction("eyes", count: 1, pressed: false)

    page.execute_script(<<~JS, target, stale)
      window.Turbo.renderStreamMessage(`<turbo-stream action="replace" target="${arguments[0]}"><template>${arguments[1]}</template></turbo-stream>`)
    JS
    sleep 0.2
    expect(popover).to have_reaction("eyes", count: 1, pressed: false)
  end

  %w[comment thread].each do |ancestor|
    it "preserves newer reactions inside a stale #{ancestor} replacement" do
      popover = open_thread
      target = ancestor == "comment" ? "comment_#{comment.id}" : "comment_thread_#{thread_record.id}"
      stale = page.evaluate_script("document.getElementById(arguments[0]).outerHTML", target)
      create(:comment_reaction, comment: comment, user: sam, kind: "eyes")
      comment.bump_reactions_version!
      CoPlan::Broadcaster.replace_to(plan, target: "reactions_comment_#{comment.id}",
        partial: "coplan/comments/reactions", locals: { comment: comment.reload })
      expect(popover).to have_reaction("eyes", count: 1, pressed: false)

      page.execute_script(<<~JS, target, stale)
        const html = arguments[1].replace("How long do results stay warm?", "Updated comment body")
        window.Turbo.renderStreamMessage(`<turbo-stream action="replace" target="${arguments[0]}"><template>${html}</template></turbo-stream>`)
      JS
      expect(page).to have_css("##{target}", text: "Updated comment body", visible: :all)
      expect(page).to have_css("#reactions_comment_#{comment.id}[data-version='#{comment.reactions_version}'] .comment-reaction[data-kind='eyes']", visible: :all)
    end
  end

  [ [ "thumbs_up", "tada" ], [ "thumbs_up", "thumbs_up" ] ].each do |kinds|
    it "rolls back both failed queued changes for #{kinds.join(' then ')}" do
      create(:comment_reaction, comment: comment, user: sam, kind: "thumbs_up")
      create(:comment_reaction, comment: comment, user: sam, kind: "tada")
      popover = open_thread
      page.execute_script(<<~JS, kinds)
        window.reactionFailures = []
        const originalFetch = window.fetch
        window.fetch = (url, options) => options?.method === "PATCH" && String(url).endsWith("/reactions")
          ? new Promise((resolve, reject) => window.reactionFailures.push(reject))
          : originalFetch(url, options)
        for (const kind of arguments[0]) {
          document.querySelector(`.thread-popover:popover-open .comment-reaction[data-kind="${kind}"]`).click()
        }
      JS
      wait_for { page.evaluate_script("window.reactionFailures.length") == 1 }
      page.execute_script("window.reactionFailures.shift()(new Error('offline'))")
      wait_for { page.evaluate_script("window.reactionFailures.length") == 1 }
      page.execute_script("window.reactionFailures.shift()(new Error('offline'))")
      expect(page).to have_css(".toasts__toast", text: "Couldn't save your reaction.", count: 2)
      expect(popover).to have_reaction("thumbs_up", count: 1, pressed: false)
      expect(popover).to have_reaction("tada", count: 1, pressed: false)
      expect(comment.reactions.where(user: viewer)).to be_empty
    end
  end

  it "keeps reactions working in a cloned table discussion" do
    table_comment = create_table_thread.comments.first
    create(:comment_reaction, comment: table_comment, user: viewer, kind: "thumbs_up")
    create(:comment_reaction, comment: table_comment, user: sam, kind: "thumbs_up")
    create(:comment_reaction, comment: table_comment, user: sam, kind: "tada")
    original = "#reactions_comment_#{table_comment.id}"
    panel = open_table_discussion

    expect(panel).to have_css(".comment-reactions", count: 1)
    expect(panel).to have_reaction("thumbs_up", count: 2, pressed: true)
    expect(panel).to have_reaction("tada", count: 1, pressed: false)

    chip(panel, "🎉").click
    expect(panel).to have_reaction("tada", count: 2, pressed: true)
    wait_for { table_comment.reactions.where(user: viewer, kind: "tada").exists? }
    expect(page).to have_css("#{original} .comment-reaction[data-kind='tada'][aria-pressed='true'] .comment-reaction__count",
      exact_text: "2", visible: :all)
    expect(panel).to have_css(".comment-reactions[data-version='#{table_comment.reload.reactions_version}']")

    chip(panel, "👍").click
    expect(panel).to have_reaction("thumbs_up", count: 1, pressed: false)
    wait_for { !table_comment.reactions.where(user: viewer, kind: "thumbs_up").exists? }
    expect(page).to have_css("#{original} .comment-reaction[data-kind='thumbs_up'][aria-pressed='false'] .comment-reaction__count",
      exact_text: "1", visible: :all)
    expect(panel).to have_css(".comment-reactions", count: 1)
  end
end
