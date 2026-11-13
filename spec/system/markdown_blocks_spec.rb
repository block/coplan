require "rails_helper"

RSpec.describe "Markdown blocks", type: :system do
  let(:author) { create(:coplan_user, email: "markdown-blocks@example.com") }
  let(:content) do
    <<~MARKDOWN
      # Update

      Intro before the draft.

      ```markdown
      **Progress**

      * The rollout is done. See [release notes](https://example.com/r/42) for details.
      * Hardening continues.

      ## Plans

      Ship the cleanup.
      ```

      The rollout is done outside the draft too.

      ## After
    MARKDOWN
  end
  let(:plan) do
    CoPlan::Plans::Create.call(title: "Update", content: content, user: author,
      visibility: "published", actor_type: "human")
  end

  before do
    allow(CoPlan::Ai).to receive(:available?).and_return(false)
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  def block
    find(".markdown-block")
  end

  # Selects from start_text (+start_offset) to end_text (+end_offset), each
  # looked up among the text nodes under root_selector.
  def select_in(root_selector, start_text, start_offset, end_text, end_offset)
    page.execute_script(<<~JS, root_selector, start_text, start_offset, end_text, end_offset)
      const [rootSelector, startText, startOffset, endText, endOffset] = arguments;
      const root = document.querySelector(rootSelector);
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      const nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      const find = text => nodes.find(node => node.textContent.includes(text));
      const startNode = find(startText);
      const endNode = find(endText);
      const range = document.createRange();
      range.setStart(startNode, startNode.textContent.indexOf(startText) + startOffset);
      range.setEnd(endNode, endNode.textContent.indexOf(endText) + endOffset);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      document.querySelector('[data-coplan--text-selection-target="content"]').dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    JS
  end

  def comment_on_selection(body)
    count = plan.comment_threads.count
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: body
    panel.find("textarea").send_keys(:enter)
    deadline = 10.seconds.from_now
    sleep 0.1 until plan.comment_threads.count > count || Time.current > deadline
    expect(plan.comment_threads.count).to eq(count + 1)
  end

  def marked_text(scope)
    page.evaluate_script(<<~JS, scope)
      Array.from(document.querySelectorAll(arguments[0] + " mark.anchor-highlight")).map(mark => mark.textContent).join("")
    JS
  end

  it "shows a markdown fence rendered, switches to its source, and keeps it out of the outline" do
    visit plan_page_path(plan)

    within(block) do
      expect(page).to have_css("button[aria-pressed='true']", text: "Rendered")
      expect(page).to have_css("button[aria-pressed='false']", text: "Source")
      expect(page).to have_css("strong", text: "Progress")
      expect(page).to have_link("release notes", href: "https://example.com/r/42")
      expect(page).to have_css("h2", text: "Plans")
      expect(page).to have_no_css("pre", visible: true)

      click_button "Source"
      expect(page).to have_css("button[aria-pressed='true']", text: "Source")
      expect(page).to have_css("pre", text: "**Progress**", visible: true)
      expect(page).to have_no_css(".markdown-block__rendered", visible: true)

      click_button "Rendered"
      expect(page).to have_css("strong", text: "Progress", visible: true)
      expect(page).to have_no_css("pre", visible: true)
    end

    outline = find("[data-coplan--content-nav-target='list']", visible: :all)
    expect(outline).to have_css("a", text: "After", visible: :all, wait: 10)
    expect(outline).to have_no_css("a", text: "Plans", visible: :all)
  end

  it "stores a rendered selection as its source and shows the comment in both views" do
    visit plan_page_path(plan)
    expect(page).to have_css(".markdown-block code.hljs", visible: :all, wait: 10)

    # From inside the link text to past it: the stored anchor is the source
    # of that passage, including the link's URL.
    select_in(".markdown-block__rendered", "release notes", 0, "for details", 11)
    comment_on_selection("Link the changelog instead")

    thread = plan.comment_threads.last
    expect(thread.anchor_text).to eq("release notes](https://example.com/r/42) for details")
    expect(content[thread.anchor_start...thread.anchor_end]).to eq(thread.anchor_text)
    expect(marked_text(".markdown-block__rendered")).to eq("release notes for details")

    within(block) { click_button "Source" }
    expect(page).to have_css(".markdown-block pre mark.anchor-highlight", wait: 10)
    expect(marked_text(".markdown-block pre")).to eq("release notes](https://example.com/r/42) for details")

    # A comment made on the source shows over the rendered text.
    select_in(".markdown-block pre", "**Progress**", 0, "**Progress**", 12)
    comment_on_selection("Use a heading")
    expect(plan.comment_threads.order(:created_at).last.anchor_text).to eq("**Progress**")

    visit plan_page_path(plan)
    expect(page).to have_css("button[aria-pressed='true']", text: "Rendered")
    expect(page).to have_css(".markdown-block__rendered strong mark.anchor-highlight", text: "Progress", wait: 10)
    expect(marked_text(".markdown-block__rendered")).to eq("Progressrelease notes for details")

    find(".markdown-block__rendered mark.anchor-highlight", text: "Progress").click
    expect(page).to have_css(".thread-popover:popover-open", text: "Use a heading", wait: 5)
  end

  it "anchors repeated text to the copy that was selected" do
    visit plan_page_path(plan)
    expect(page).to have_css(".markdown-block code.hljs", visible: :all, wait: 10)

    select_in("#plan-content-body", "outside the draft", -20, "outside the draft", -1)
    comment_on_selection("Outside comment")
    outside = plan.comment_threads.last
    expect(outside.anchor_text).to eq("The rollout is done")
    expect(outside.anchor_start).to eq(content.rindex("The rollout is done"))

    select_in(".markdown-block__rendered", "The rollout is done", 0, "The rollout is done", 19)
    comment_on_selection("Inside comment")
    inside = plan.comment_threads.order(:created_at).last
    expect(inside.anchor_start).to eq(content.index("The rollout is done"))

    visit plan_page_path(plan)
    expect(page).to have_css(".markdown-block__rendered mark.anchor-highlight", text: "The rollout is done", wait: 10)
    expect(page).to have_css("#plan-content-body > .markdown-rendered > p mark.anchor-highlight", text: "The rollout is done")
  end

  it "keeps the chosen view through a live update that adds a block above" do
    visit plan_page_path(plan)
    within(block) { click_button "Source" }
    expect(page).to have_css(".markdown-block pre", visible: true)

    updated = plan.current_content.sub("Intro before the draft.\n", "Intro before the draft.\n\n```md\nAn *earlier* draft.\n```\n")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: updated,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)

    expect(page).to have_css(".markdown-block", count: 2, wait: 10)
    first, second = all(".markdown-block")
    expect(first).to have_css("em", text: "earlier", visible: true)
    expect(first).to have_css("button[aria-pressed='true']", text: "Rendered")
    expect(second).to have_css("pre", text: "**Progress**", visible: true)
    expect(second).to have_css("button[aria-pressed='true']", text: "Source")
  end

  it "maps rendered text after an emoji and leaves footnote numbers out" do
    notes = CoPlan::Plans::Create.call(title: "Notes", user: author, visibility: "published", actor_type: "human",
      content: "# Notes\n\n```markdown\n\u{1F680} **Shipped** the beta.[^1]\n\n[^1]: Beta notes.\n```\n")
    visit plan_page_path(notes)
    expect(page).to have_css(".markdown-block code.hljs", visible: :all, wait: 10)

    # From the bold word through the footnote number after the sentence.
    page.execute_script(<<~JS)
      const pane = document.querySelector(".markdown-block__rendered");
      const start = pane.querySelector("strong").firstChild;
      const end = pane.querySelector("[data-footnote-ref]").firstChild;
      const range = document.createRange();
      range.setStart(start, 0);
      range.setEnd(end, end.textContent.length);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      document.querySelector('[data-coplan--text-selection-target="content"]').dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    JS
    count = notes.comment_threads.count
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: "Name the beta"
    panel.find("textarea").send_keys(:enter)
    deadline = 10.seconds.from_now
    sleep 0.1 until notes.comment_threads.count > count || Time.current > deadline

    thread = notes.comment_threads.last
    expect(thread.anchor_text).to eq("Shipped** the beta.")
    expect(page).to have_css(".markdown-block__rendered strong mark.anchor-highlight", text: "Shipped", wait: 10)
    expect(marked_text(".markdown-block__rendered")).to eq("Shipped the beta.")
  end
end
