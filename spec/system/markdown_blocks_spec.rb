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
        * A nested detail.
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

  it "keeps the chosen view while an edit changes the block" do
    visit plan_page_path(plan)
    within(block) { click_button "Source" }

    updated = plan.current_content.sub("Ship the cleanup.", "Ship the cleanup this week.")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: updated,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)

    expect(page).to have_css(".markdown-block pre", text: "this week", visible: true, wait: 10)
    expect(page).to have_css(".markdown-block button[aria-pressed='true']", text: "Source")
  end

  it "maps text after formatting to the copy that follows it" do
    bold = CoPlan::Plans::Create.call(title: "Bold", user: author, visibility: "published", actor_type: "human",
      content: "# Bold\n\n```markdown\n**foo bar** bar\n```\n")
    visit plan_page_path(bold)
    expect(page).to have_css(".markdown-block code.hljs", visible: :all, wait: 10)

    page.execute_script(<<~JS)
      const pane = document.querySelector(".markdown-block__rendered");
      const tail = pane.querySelector("strong").nextSibling;
      const range = document.createRange();
      range.setStart(tail, 1);
      range.setEnd(tail, 4);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      document.querySelector('[data-coplan--text-selection-target="content"]').dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    JS
    count = bold.comment_threads.count
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: "Second bar"
    panel.find("textarea").send_keys(:enter)
    deadline = 10.seconds.from_now
    sleep 0.1 until bold.comment_threads.count > count || Time.current > deadline

    thread = bold.comment_threads.last
    expect(thread.anchor_start).to eq(bold.current_content.rindex("bar"))
    expect(page).to have_css(".markdown-block__rendered mark.anchor-highlight", text: "bar", count: 1, wait: 10)
    expect(page).to have_no_css(".markdown-block__rendered strong mark.anchor-highlight")
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

  it "keeps Source through an edit to the draft and insertion of an identical draft" do
    visit plan_page_path(plan)
    within(block) { click_button "Source" }
    updated = content.sub("Ship the cleanup.", "Ship the cleanup tomorrow.")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: updated,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    expect(page).to have_css(".markdown-block pre", text: "cleanup tomorrow", visible: true)

    duplicate = updated[/```markdown.*?```/m]
    updated = "#{duplicate}\n\n#{updated}"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: updated,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    expect(page).to have_css(".markdown-block", count: 2)
    expect(all(".markdown-block").first).to have_css("button[aria-pressed=true]", text: "Rendered")
    expect(all(".markdown-block").last).to have_css("button[aria-pressed=true]", text: "Source")
  end

  it "keeps Source on the edited original when identical drafts diverge" do
    fence = "```md\nA **draft** that will change.\n```\n"
    sample = CoPlan::Plans::Create.call(title: "Two drafts", user: author, visibility: "published", actor_type: "human",
      content: "# Two drafts\n\n#{fence}\nBetween drafts.\n\n#{fence}")
    visit plan_page_path(sample)
    within(all(".markdown-block").last) { click_button "Source" }
    updated = sample.current_content.sub(/that will change\.(?=\n```\n\z)/, "that changed today.")
    CoPlan::Plans::ReplaceContent.call(plan: sample, new_content: updated,
      base_revision: sample.current_revision, actor_type: "human", actor_id: author.id)
    expect(page).to have_css(".markdown-block pre", text: "changed today", visible: true)
    expect(all(".markdown-block").first).to have_css("button[aria-pressed=true]", text: "Rendered")
    expect(all(".markdown-block").last).to have_css("button[aria-pressed=true]", text: "Source")
  end

  it "allows Source switching during writing inspection" do
    visit plan_page_path(plan)
    find(".writing-provenance__trigger").click
    click_button "Inspect writing"
    expect(page).to have_button("Done inspecting")
    within(block) { click_button "Source" }
    expect(page).to have_css(".markdown-block pre", visible: true)
    expect(page.evaluate_script(<<~JS)).to be_positive
      [...CSS.highlights.values()].flatMap(highlight => [...highlight]).filter(range => range.startContainer.parentElement.closest("[data-markdown-block-source]")).length
    JS
    within(block) { click_button "Rendered" }
    expect(page).to have_css(".markdown-block__rendered", visible: true)
  end

  it "comments across the boundary between a rendered draft and ordinary prose" do
    visit plan_page_path(plan)
    select_in("#plan-content-body", "Ship the cleanup.", 0, "outside the draft", 17)
    comment_on_selection("Review the ending together")
    thread = plan.comment_threads.last
    expect(thread.anchor_start).to eq(content.index("Ship the cleanup."))
    expect(thread.anchor_end).to eq(content.index("outside the draft") + 17)
  end

  it "maps an interpreted voice quote in a rendered draft back to its source" do
    visit plan_page_path(plan)
    expect(page).to have_css(".markdown-block code.hljs", visible: :all)
    expect(page).to have_css("[data-voice-ready]")
    anchor = page.evaluate_script(<<~JS)
      (() => {
      const element = document.querySelector('[data-controller~="coplan--voice"]');
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "coplan--voice");
      return controller._resolveAnchor("release notes for details");
      })()
    JS
    expect(anchor).to eq("text" => "release notes](https://example.com/r/42) for details", "occurrence" => 1)
    within(block) { click_button "Source" }
    expect(page.evaluate_script(<<~JS)).to be_nil
      window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~="coplan--voice"]'), "coplan--voice")._resolveAnchor("release notes for details")
    JS
  end

  it "keeps a formatted draft quote through server interpretation and browser projection" do
    sample = CoPlan::Plans::Create.call(title: "Deployment", user: author, visibility: "published", actor_type: "human",
      content: "# Deployment\n\n```md\nDo **not** deploy.\n```\n")
    allow(CoPlan::Ai).to receive(:call).and_return({ text: "Keep this warning.", span: "Do not deploy." }.to_json)
    visit plan_page_path(sample)
    expect(page).to have_css("[data-voice-ready]")
    result = page.evaluate_async_script(<<~JS, plan_dictations_path(sample))
      const url = arguments[0], done = arguments[arguments.length - 1];
      fetch(url, { method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
        body: JSON.stringify({transcript: "Keep this warning.", excerpt: "Do not deploy."}) })
        .then(response => response.json()).then(data => {
          const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~="coplan--voice"]'), "coplan--voice");
          done({quote: data.anchor_text, anchor: controller._resolveAnchor(data.anchor_text)});
        }).catch(error => done({error:error.message}));
    JS
    expect(result).to eq("quote" => "Do not deploy.", "anchor" => { "text" => "Do **not** deploy.", "occurrence" => 1 })
  end

  it "comments on expanded draft table cells and shows the discussion in Source" do
    table_plan = CoPlan::Plans::Create.call(title: "Draft table", user: author, visibility: "published", actor_type: "human",
      content: "# Draft table\n\n<details open>\n<summary>Draft table</summary>\n\n```md\n| Client | Attempts |\n|---|---|\n| Mobile | **3** |\n| Web | **3** |\n```\n\n</details>\n")
    visit plan_page_path(table_plan)
    cell = all(".markdown-block tbody tr").last.all("td").last
    cell.double_click
    expect(page).to have_css("dialog.expander[open]")
    selected = find("dialog td.is-cursor")
    selected.send_keys("c")
    panel = find(".source-comments:popover-open")
    expect(panel).to have_css("textarea:focus")
    panel.fill_in "Write a comment...", with: "Check the web budget"
    panel.click_button "Comment", exact: true
    expect(panel).to have_text("Check the web budget")
    thread = table_plan.comment_threads.last
    expect(thread.anchor_kind).to eq("table_cell")
    expect(thread.anchor_start).to eq(table_plan.current_content.rindex(" **3** "))
    page.driver.browser.action.send_keys(:escape).perform
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_no_css("dialog.expander[open]")
    within(block) { click_button "Source" }
    expect(page).to have_css(".markdown-block pre mark", text: "**3**")
    page.driver.browser.action.send_keys("j").perform
    expect(page).to have_css(".thread-popover:popover-open", text: "Check the web budget")
    page.driver.browser.action.send_keys(:escape).perform

    CoPlan::Plans::ReplaceContent.call(plan: table_plan, new_content: "Intro.\n\n#{table_plan.current_content}",
      base_revision: table_plan.current_revision, actor_type: "human", actor_id: author.id)
    expect(thread.reload).not_to be_out_of_date
    expect(page).to have_css(".markdown-block pre mark", text: "**3**")
    find("details > summary", text: "Draft table").click
    find("summary .details-comment-badge").click
    expect(page).to have_css(".thread-popover:popover-open", text: "Check the web budget")
    expect(page).to have_css(".markdown-block pre mark", text: "**3**", visible: true)
    page.driver.browser.action.send_keys(:escape).perform
    within(block) { click_button "Rendered" }
    find("details > summary", text: "Draft table").click
    find("summary .details-comment-badge").click
    expect(page).to have_css(".source-comments:popover-open", text: "Check the web budget")
  end

  it "maps visible repetitions after image alt text and generated footnote numbers" do
    sample = CoPlan::Plans::Create.call(title: "Visible text", user: author, visibility: "published", actor_type: "human",
      content: "# Visible text\n\n```md\n![Status](https://example.com/status.png) Status\n\nFoo[^n]1\n\n[^n]: A note.\n```\n")
    visit plan_page_path(sample)
    expect(page).to have_css(".markdown-block code.hljs", visible: :all)
    mapped = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      import("coplan/markdown_blocks").then(({ sourceRangeFor, sourceOffset }) => {
        const block = document.querySelector(".markdown-block");
        const paragraphs = block.querySelectorAll(".markdown-block__rendered > p");
        done(Array.from(paragraphs).map(p => {
          const node = p.lastChild;
          const range = document.createRange();
          range.setStart(node, node.textContent.search(/\\S/)); range.setEnd(node, node.length);
          const mapped = sourceRangeFor(range);
          return mapped && { text: mapped.toString(), offset: sourceOffset(block, mapped.startContainer, mapped.startOffset) };
        }));
      }).catch(error => done({ error: error.message }));
    JS
    body = sample.current_content.split("```md\n").last
    expect(mapped).to eq([
      { "text" => "Status", "offset" => body.index(" Status") + 1 },
      { "text" => "1", "offset" => body.index("]1") + 1 }
    ])
  end

  it "maps authored HTML text without trusting its source-position attributes" do
    sample = CoPlan::Plans::Create.call(title: "HTML draft", user: author, visibility: "published", actor_type: "human",
      content: "# HTML draft\n\n```md\nSame\n\n<div><span title=\"x\"data-sourcepos=\"1:1-1:4\">Same</span></div>\n```\n")
    visit plan_page_path(sample)
    expect(page).to have_css(".markdown-block code.hljs", visible: :all)
    select_in(".markdown-block__rendered > div", "Same", 0, "Same", 4)
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: "HTML discussion"
    panel.find("textarea").send_keys(:enter)
    expect(page).to have_css(".markdown-block__rendered > div mark", text: "Same")
    expect(sample.comment_threads.last.anchor_start).to eq(sample.current_content.rindex("Same"))
    within(block) { click_button "Source" }
    expect(page).to have_css(".markdown-block pre mark", text: "Same")
  end

  { "> div:first-child" => 0, "> div > span" => 1, "> div > em" => 2, "> div:last-child" => 3 }.each do |selector, occurrence|
    it "anchors repeated raw HTML occurrence #{occurrence} without highlighting the others" do
      sample = CoPlan::Plans::Create.call(title: "Repeated HTML", user: author, visibility: "published", actor_type: "human",
        content: "# Repeated HTML\n\n```md\n<div>Same <span>Same</span><em>Same</em></div><div>Same</div>\n```\n")
      visit plan_page_path(sample)
      select_in(".markdown-block__rendered #{selector}", "Same", 0, "Same", 4)
      page.driver.browser.action.send_keys("c").perform
      panel = find(".comment-window:popover-open")
      panel.find("textarea").fill_in with: "Only occurrence #{occurrence}"
      panel.find("textarea").send_keys(:enter)
      expect(page).to have_css(".markdown-block__rendered mark", text: "Same", count: 1)
      expected = sample.current_content.enum_for(:scan, "Same").map { Regexp.last_match.begin(0) }.fetch(occurrence)
      expect(sample.comment_threads.last.anchor_start).to eq(expected)
      within(block) { click_button "Source" }
      expect(page).to have_css(".markdown-block pre mark", text: "Same", count: 1)
    end
  end

  it "renders and comments on HTML with tag-like quoted attribute values" do
    sample = CoPlan::Plans::Create.call(title: "Quoted HTML", user: author, visibility: "published", actor_type: "human",
      content: %Q(# Quoted HTML\n\n```md\n<div title="<strong>">Hello</div>\n```\n))
    visit plan_page_path(sample)
    expect(find(".markdown-block__rendered > div").text).to eq("Hello")
    select_in(".markdown-block__rendered > div", "Hello", 0, "Hello", 5)
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: "Hello discussion"
    panel.find("textarea").send_keys(:enter)
    expect(page).to have_css(".markdown-block__rendered mark", text: "Hello", count: 1)
    expect(sample.comment_threads.last.anchor_start).to eq(sample.current_content.index("Hello"))
  end

  it "keeps raw HTML separate from identical relocated footnote definitions" do
    sample = CoPlan::Plans::Create.call(title: "Footnote order", user: author, visibility: "published", actor_type: "human",
      content: "# Footnote order\n\n```md\nA[^x]\n\n[^x]: Same\n\n<div>Same</div>\n```\n")
    visit plan_page_path(sample)
    select_in(".markdown-block__rendered > div", "Same", 0, "Same", 4)
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: "Only the HTML passage"
    panel.find("textarea").send_keys(:enter)
    expect(page).to have_css(".markdown-block__rendered > div mark", text: "Same")
    expect(page).to have_no_css(".markdown-block__rendered [data-footnotes] mark")
    expect(sample.comment_threads.last.anchor_start).to eq(sample.current_content.rindex("Same"))
  end

  it "maps tight-list prose after a Mermaid diagram to the prose occurrence" do
    sample = CoPlan::Plans::Create.call(title: "Diagram followed by prose", user: author, visibility: "published", actor_type: "human",
      content: "# Draft\n\n````md\n- Intro\n  ```mermaid\n  flowchart LR\n    A[Done]\n  ```\n  Done\n````\n")
    visit plan_page_path(sample)
    expect(page).to have_css(".markdown-block .mermaid-diagram svg", wait: 20)
    page.execute_script(<<~JS)
      const item = document.querySelector(".markdown-block__rendered li");
      const node = Array.from(item.childNodes).find(n => n.nodeType === Node.TEXT_NODE && n.textContent.includes("Done"));
      const range = document.createRange();
      const start = node.textContent.indexOf("Done");
      range.setStart(node, start); range.setEnd(node, start + 4);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      document.querySelector('[data-coplan--text-selection-target="content"]').dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    JS
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: "Only the prose after the diagram"
    panel.find("textarea").send_keys(:enter)
    expect(page).to have_css(".markdown-block__rendered li > mark", text: "Done", count: 1)
    expect(sample.comment_threads.last.anchor_start).to eq(sample.current_content.rindex("Done"))
    within(block) { click_button "Source" }
    expect(page).to have_css(".markdown-block pre mark", text: "Done", count: 1)
  end

  it "comments on nested draft diagrams inline and expanded and highlights their Source" do
    sample = CoPlan::Plans::Create.call(title: "Diagram draft", user: author, visibility: "published", actor_type: "human",
      content: "# Diagram draft\n\n````md\n🚀\n\n```mermaid\nflowchart LR\n A[Start] --> B[End]\n```\n````\n")
    visit plan_page_path(sample)
    expect(page).to have_css(".markdown-block .mermaid-diagram g.node[data-source-target]", count: 2, wait: 20)
    find(".mermaid-diagram").send_keys("c")
    find(".mermaid-diagram g.node[data-source-target]", text: "End").click
    panel = find(".source-comments:popover-open")
    panel.fill_in "Write a comment...", with: "Review the ending"
    panel.click_button "Comment", exact: true
    expect(panel).to have_text("Review the ending")
    thread = sample.comment_threads.last
    expect(thread.anchor_kind).to eq("mermaid_node")
    expect(thread.anchor_text).to eq("B[End]")
    expect(thread.anchor_start).to eq(sample.current_content.index("B[End]"))
    panel.find('[aria-label="Close element comments"]').click
    find(".mermaid-diagram").send_keys(:escape)
    find(".mermaid-diagram").hover
    find(".mermaid-diagram__expand").click
    find(".expander__canvas").send_keys("c")
    find("dialog g.node[data-source-target]", text: "Start").click
    expect(page).to have_css(".source-comments:popover-open textarea:focus")
    find(".source-comments:popover-open [aria-label='Close element comments']").click
    find('dialog [aria-label="Close"]').click
    within(block) { click_button "Source" }
    expect(page).to have_css(".markdown-block pre mark", text: "B[End]")
    page.driver.browser.action.send_keys("j").perform
    expect(page).to have_css(".thread-popover:popover-open", text: "Review the ending")
    CoPlan::Plans::ReplaceContent.call(plan: sample, new_content: "Intro.\n\n#{sample.current_content}",
      base_revision: sample.current_revision, actor_type: "human", actor_id: author.id)
    expect(thread.reload).not_to be_out_of_date
  end

  it "highlights an empty draft cell's delimiters and navigates to it in Source" do
    sample = CoPlan::Plans::Create.call(title: "Empty cell", user: author, visibility: "published", actor_type: "human",
      content: "# Empty cell\n\n```md\n🚀\n\n| A | B |\n|---|---|\n| Web ||\n```\n")
    visit plan_page_path(sample)
    cell = all(".markdown-block tbody td").last
    cell.click
    cell.send_keys("c")
    panel = find(".source-comments:popover-open")
    panel.fill_in "Write a comment...", with: "Fill this cell"
    panel.click_button "Comment", exact: true
    expect(panel).to have_text("Fill this cell")
    expect(sample.comment_threads.last.anchor_text).to eq("||")
    page.driver.browser.action.send_keys(:escape).perform
    within(block) { click_button "Source" }
    expect(page).to have_css(".markdown-block pre mark", text: "||")
    page.driver.browser.action.send_keys("k").perform
    expect(page).to have_css(".thread-popover:popover-open", text: "Fill this cell")
  end

  it "maps repeated words after formatting and complete entities without guessing" do
    sample = CoPlan::Plans::Create.call(title: "Exact source", user: author, visibility: "published", actor_type: "human",
      content: "# Exact source\n\n```markdown\n**word word** word\n\nCopyright &#169; &amp; \\*ready\\* 🚀\n```\n")
    visit plan_page_path(sample)
    expect(page).to have_css(".markdown-block code.hljs", visible: :all)

    mapped = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      import("coplan/markdown_blocks").then(({ sourceRangeFor }) => {
        const pane = document.querySelector(".markdown-block__rendered");
        const paragraphs = pane.querySelectorAll("p");
        const result = [];
        const select = (node, from, to) => {
          const range = document.createRange();
          range.setStart(node, from); range.setEnd(node, to);
          const mapped = sourceRangeFor(range);
          result.push(mapped && { text: mapped.toString(), offset: mapped.startOffset });
        };
        const tail = paragraphs[0].lastChild;
        select(tail, 1, 5);
        const entity = paragraphs[1].firstChild;
        select(entity, entity.textContent.indexOf("©"), entity.textContent.indexOf("©") + 1);
        select(entity, entity.textContent.indexOf("&"), entity.textContent.indexOf("&") + 1);
        done(result);
      }).catch(error => done({ error: error.message }));
    JS
    expect(mapped.map { |entry| entry && entry["text"] }).to eq([ "word", "&#169;", "&amp;" ])
    # The final copy must map past the bold word, not back to the first copy.
    # Compare the source range directly; syntax highlighting may split nodes.
    page.execute_script(<<~JS)
      const node = document.querySelector(".markdown-block__rendered p").lastChild;
      const range = document.createRange(); range.setStart(node, 1); range.setEnd(node, 5);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      document.querySelector('[data-coplan--text-selection-target="content"]').dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    JS
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: "The final word"
    panel.find("textarea").send_keys(:enter)
    expect(page).to have_css(".thread-popover", text: "The final word", visible: :all)
    expect(sample.comment_threads.last.anchor_start).to eq(sample.current_content.index("** word") + 3)
  end

  describe "default view setting" do
    it "opens blocks in the view picked under Settings, page by page" do
      visit settings_root_path
      row = find(".settings-row", text: "Markdown blocks")
      within(row) { find(".segmented__option", text: "Source").click }
      expect(page).to have_css("html[data-markdown-block-view='source']", visible: :all, wait: 10)
      expect(author.reload.markdown_block_view).to eq("source")

      thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "**Progress**")
      create(:comment, comment_thread: thread, author_id: author.id, body_markdown: "Use a heading")

      visit plan_page_path(plan)
      within(block) do
        expect(page).to have_css("button[aria-pressed='true']", text: "Source")
        expect(page).to have_css("pre", text: "**Progress**", visible: true)
        expect(page).to have_no_css(".markdown-block__rendered", visible: true)
        expect(page).to have_css("pre mark.anchor-highlight", text: "**Progress**", wait: 10)

        # Switching on the page still works, for this page only.
        click_button "Rendered"
        expect(page).to have_css("strong mark.anchor-highlight", text: "Progress", visible: true, wait: 10)
      end

      visit plan_page_path(plan)
      expect(page).to have_css(".markdown-block button[aria-pressed='true']", text: "Source")
    end

    it "keeps a block switched to Rendered through a live update" do
      author.update!(markdown_block_view: "source")
      visit plan_page_path(plan)
      within(block) { click_button "Rendered" }

      updated = plan.current_content.sub("Ship the cleanup.", "Ship the cleanup this week.")
      CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: updated,
        base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)

      expect(page).to have_css(".markdown-block__rendered", text: "this week", visible: true, wait: 10)
      expect(page).to have_css(".markdown-block button[aria-pressed='true']", text: "Rendered")
    end

    it "shows a Source default before the block's controller connects" do
      author.update!(markdown_block_view: "source")
      visit plan_page_path(plan)
      expect(page).to have_css(".markdown-block[data-view='source']")

      # A copy with no controller is what the first paint sees.
      styles = page.evaluate_script(<<~JS)
        (() => {
          const copy = document.querySelector(".markdown-block").cloneNode(true);
          copy.removeAttribute("data-controller");
          copy.removeAttribute("data-view");
          copy.querySelector("[data-markdown-block-rendered]").hidden = false;
          copy.querySelector("pre[data-markdown-block-source]").hidden = true;
          document.querySelector("#plan-content-body .markdown-rendered").append(copy);
          const shown = element => getComputedStyle(element).display !== "none";
          const result = {
            rendered: shown(copy.querySelector("[data-markdown-block-rendered]")),
            source: shown(copy.querySelector("pre[data-markdown-block-source]"))
          };
          copy.remove();
          return result;
        })()
      JS
      expect(styles).to eq("rendered" => false, "source" => true)
    end

    # Delays (and optionally fails) this tab's saves of the setting, so a
    # test can navigate while they are in flight.
    def delay_view_saves(ms, status: nil)
      page.execute_script(<<~JS, ms, status)
        const [ms, status] = arguments;
        const original = window.fetch;
        window.fetch = (url, options) => String(url).includes("markdown_block_view")
          ? new Promise(resolve => setTimeout(resolve, ms)).then(() => status ? new Response("", { status }) : original(url, options))
          : original(url, options);
      JS
    end

    def view_row
      find(".settings-row", text: "Markdown blocks")
    end

    it "takes a choice changed elsewhere from a fresh Settings render" do
      visit plan_page_path(plan)
      expect(page).to have_css("html[data-markdown-block-view='rendered']", visible: :all)

      # Another tab or device saves Source; this tab's <html> still says Rendered.
      author.update!(markdown_block_view: "source")
      page.execute_script("Turbo.visit(arguments[0])", settings_root_path)
      within(view_row) { expect(page).to have_checked_field("markdown_block_view", with: "source", visible: :all) }
      expect(page).to have_css("html[data-markdown-block-view='source']", visible: :all)

      page.execute_script("Turbo.visit(arguments[0])", plan_page_path(plan))
      expect(page).to have_css(".markdown-block button[aria-pressed='true']", text: "Source")
    end

    it "keeps a saved choice when Turbo restores Settings from its cache" do
      visit settings_root_path
      within(view_row) { find(".segmented__option", text: "Source").click }
      expect(page).to have_css("html[data-markdown-block-view='source']", visible: :all)
      page.execute_script("Turbo.visit(arguments[0])", plan_page_path(plan))
      expect(page).to have_css(".markdown-block button[aria-pressed='true']", text: "Source")

      # The cached Settings page was rendered when Rendered was stored.
      page.go_back
      within(view_row) { expect(page).to have_checked_field("markdown_block_view", with: "source", visible: :all) }
      expect(page).to have_css("html[data-markdown-block-view='source']", visible: :all)
    end

    it "keeps saves in pick order across Settings visits" do
      visit settings_root_path
      delay_view_saves(400)
      within(view_row) do
        find(".segmented__option", text: "Source").click
        find(".segmented__option", text: "Rendered").click
      end
      page.execute_script("Turbo.visit(arguments[0])", plan_page_path(plan))
      expect(page).to have_css(".markdown-block")
      page.execute_script("Turbo.visit(arguments[0])", settings_root_path)
      within(view_row) { find(".segmented__option", text: "Source").click }

      deadline = 10.seconds.from_now
      sleep 0.1 until page.evaluate_script("document.documentElement.dataset.markdownBlockView") == "source" || Time.current > deadline
      sleep 1.5 # Long enough for every queued save to land.
      expect(author.reload.markdown_block_view).to eq("source")
      expect(page).to have_css("html[data-markdown-block-view='source']", visible: :all)
      within(view_row) { expect(page).to have_checked_field("markdown_block_view", with: "source", visible: :all) }
    end

    it "restores the active Settings row when a detached save fails and allows retry" do
      visit settings_root_path
      page.execute_script(<<~JS)
        const original = window.fetch;
        let attempts = 0;
        window.fetch = (url, options) => String(url).includes("markdown_block_view") && ++attempts === 1
          ? new Promise(resolve => setTimeout(() => resolve(new Response("", {status: 500})), 1000))
          : original(url, options);
      JS
      within(view_row) { find(".segmented__option", text: "Source").click }
      page.execute_script("Turbo.visit(arguments[0])", plan_page_path(plan))
      expect(page).to have_css(".markdown-block")
      page.execute_script("Turbo.visit(arguments[0])", settings_root_path)
      within(view_row) { expect(page).to have_checked_field("markdown_block_view", with: "source", visible: :all) }
      expect(page).to have_css(".toasts__toast", text: "Couldn't save your Markdown block view")
      within(view_row) do
        expect(page).to have_checked_field("markdown_block_view", with: "rendered", visible: :all)
        find(".segmented__option", text: "Source").click
      end
      expect(page).to have_css("html[data-markdown-block-view='source']", visible: :all)
      expect(author.reload.markdown_block_view).to eq("source")
    end

    it "opens a linked draft cell against its visible Source mark on a Turbo visit" do
      author.update!(markdown_block_view: "source")
      sample = CoPlan::Plans::Create.call(title: "Linked draft", user: author, visibility: "published", actor_type: "human",
        content: ("Intro paragraph.\n\n" * 40) + "```md\n| Client | Budget |\n|---|---|\n| Web | **3** |\n```\n")
      html = CoPlan::ApplicationController.helpers.render_markdown(sample.current_content, source_comments: true)
      target = JSON.parse(Nokogiri::HTML.fragment(html).css(".markdown-block td[data-source-target]").last["data-source-target"])
      thread = sample.comment_threads.create!(plan_version: sample.current_plan_version, source_token: target.fetch("token"), created_by_user: author)
      thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Review this budget")
      visit settings_root_path
      page.execute_script("Turbo.visit(arguments[0])", plan_page_path(sample, thread: thread.id))
      expect(page).to have_css(".thread-popover:popover-open", text: "Review this budget")
      expect(page).to have_no_css(".source-comments:popover-open")
      mark = find(".markdown-block pre mark", text: "**3**")
      expect(mark.evaluate_script("this.getBoundingClientRect().top")).to be_between(0, page.evaluate_script("window.innerHeight"))
    end

    it "says page-wide when a save fails after leaving Settings" do
      visit settings_root_path
      delay_view_saves(600, status: 500)
      within(view_row) { find(".segmented__option", text: "Source").click }
      page.execute_script("Turbo.visit(arguments[0])", plan_page_path(plan))

      expect(page).to have_css(".toasts__toast", text: "Couldn't save your Markdown block view", wait: 10)
      expect(page).to have_css("html[data-markdown-block-view='rendered']", visible: :all)
      expect(author.reload.markdown_block_view).to eq("rendered")
    end
  end
end
