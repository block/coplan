require "rails_helper"

RSpec.describe "Math rendering", type: :system do
  let(:author) { create(:coplan_user, email: "math@example.com") }
  let(:content) do
    <<~'MARKDOWN'
      # Math

      The relation $E = mc^2$ links mass and energy.

      $$
      \int_0^1 x^2\,dx = \tfrac{1}{3}
      $$

      ```math
      \sum_{k=1}^{n} k = \frac{n(n+1)}{2}
      ```

      Lunch costs $5 and coffee costs $10.

      Broken input $\frac{1}{$ stays readable.

      Shell code `echo $HOME` is untouched.
    MARKDOWN
  end
  let(:plan) do
    CoPlan::Plans::Create.call(title: "Math plan", content: content, user: author,
      visibility: "published", actor_type: "human")
  end

  before do
    allow(CoPlan::Ai).to receive(:available?).and_return(false)
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  def document
    find("#plan-content-body")
  end

  def select_across(start_text, start_offset, end_text, end_offset)
    page.execute_script(<<~JS, start_text, start_offset, end_text, end_offset)
      const [startText, startOffset, endText, endOffset] = arguments;
      const root = document.querySelector('[data-coplan--text-selection-target="content"]');
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      const nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      const find = text => nodes.find(node => node.textContent.includes(text));
      const startNode = startText ? find(startText) : root.querySelector('[data-math-style] .katex-html').firstChild;
      const endNode = find(endText);
      const range = document.createRange();
      range.setStart(startNode, startText ? startNode.textContent.indexOf(startText) + startOffset : 0);
      range.setEnd(endNode, endNode.textContent.indexOf(endText) + endOffset);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      root.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    JS
  end

  def comment_on_selection(body)
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: body
    panel.find("textarea").send_keys(:enter)
    expect(page).to have_css("mark.anchor-highlight", wait: 10)
  end

  it "typesets inline, display, and fenced math while currency and code stay text" do
    visit plan_page_path(plan)

    within(document) do
      expect(page).to have_css("span[data-math-style='inline'].is-math-rendered .katex", count: 1, wait: 20)
      expect(page).to have_css("span[data-math-style='display'].is-math-rendered .katex-display", wait: 10)
      expect(page).to have_css("pre[data-math-style='display'].is-math-rendered .katex-display")
      expect(page).to have_css(".katex-html", visible: true, count: 3)
      expect(page).to have_text("Lunch costs $5 and coffee costs $10.")
      expect(page).to have_css("code", text: "echo $HOME")
      expect(page).to have_no_css("pre[data-math-style] code.hljs")
    end

    # Rendered: KaTeX lays out the fraction as a tall box, not source text.
    katex = find("pre[data-math-style] .katex-html")
    expect(katex.rect.height).to be > 30
    expect(page.evaluate_script("document.querySelectorAll('link[href*=\"katex\"]').length")).to eq(1)
  end

  it "falls back to the TeX source when an expression cannot be typeset" do
    visit plan_page_path(plan)

    error = find("span[data-math-style] .katex-error", wait: 20)
    expect(error).to have_text("\\frac{1}{")
    expect(error[:title]).to include("ParseError")
    expect(find("p", text: "Broken input")).to have_text("Broken input \\frac{1}{ stays readable.")
  end

  it "does not load KaTeX on a page without math" do
    plain = CoPlan::Plans::Create.call(title: "Plain plan", content: "# Plain\n\nNo formulas; lunch costs $5 and $10.\n",
      user: author, visibility: "published", actor_type: "human")
    visit plan_page_path(plain)

    expect(page).to have_text("lunch costs $5 and $10.")
    expect(page.evaluate_script("document.querySelectorAll('link[href*=\"katex\"]').length")).to eq(0)
    expect(page.evaluate_script("performance.getEntriesByType('resource').some(entry => entry.name.includes('katex'))")).to be(false)
  end

  it "keeps source readable when the stylesheet fails and renders on a later visit" do
    page.driver.browser.execute_cdp("Network.enable")
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [ "*katex.min.css*" ])
    visit plan_page_path(plan)

    expect(page).to have_css("span[data-math-source]", text: "E = mc^2", wait: 20)
    expect(page).to have_no_css('link[href*="katex.min.css"]', visible: :all)
    expect(document).to have_no_css(".katex")
    expect(document).to have_text("Lunch costs $5 and coffee costs $10.")

    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
    visit plan_page_path(plan)
    expect(document).to have_css(".is-math-rendered .katex", wait: 20)
  ensure
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
  end

  it "does not let TeX create trusted links, images, or authored classes" do
    untrusted = CoPlan::Plans::Create.call(title: "Untrusted math", user: author,
      visibility: "published", actor_type: "human", content: <<~'MARKDOWN')
        $\href{javascript:alert(1)}{click}$

        $\includegraphics{https://example.com/math-probe.png}$

        $\htmlClass{math-probe}{x}$
      MARKDOWN
    visit plan_page_path(untrusted)

    expect(document).to have_css(".is-math-rendered", count: 3, wait: 20)
    expect(document).to have_no_css("[data-math-style] a, [data-math-style] img, .math-probe")
    expect(page.evaluate_script("performance.getEntriesByType('resource').some(entry => entry.name.includes('math-probe'))")).to be(false)
  end

  it "reads math as TeX source in the outline and section previews" do
    sections = CoPlan::Plans::Create.call(title: "Scan costs", user: author, visibility: "published", actor_type: "human",
      content: "## 1 Intro\n\nSee [§2](#section-2).\n\n## 2 Cost of $O(n)$ scans\n\nA scan of $n$ rows costs $O(n)$ time.\n")
    visit plan_page_path(sections)
    expect(page).to have_css("h2 span[data-math-style].is-math-rendered .katex", wait: 20)

    expect(page).to have_css(".content-nav__link-text", text: /\A2 Cost of O\(n\) scans\z/)
    find("a.reference-anchor--section", text: "§2").hover
    preview = find("#reference-preview", visible: true, wait: 10)
    expect(preview).to have_text("2 Cost of O(n) scans")
    expect(preview).to have_text("A scan of n rows costs O(n) time.")
    expect(preview.text).not_to include("O(n)O(n)")
  end

  it "previews a section that is only a math fence as its TeX source" do
    sections = CoPlan::Plans::Create.call(title: "Fence preview", user: author, visibility: "published", actor_type: "human",
      content: "## 1 Intro\n\nSee [§2](#section-2).\n\n## 2 Bound\n\n```math\n\\sum_{k=1}^{n} k\n```\n")
    visit plan_page_path(sections)
    expect(page).to have_css("pre[data-math-style].is-math-rendered .katex-display", wait: 20)

    find("a.reference-anchor--section", text: "§2").hover
    preview = find("#reference-preview", visible: true, wait: 10)
    expect(preview).to have_text("\\sum_{k=1}^{n} k")
    expect(preview.text.scan("\\sum").size).to eq(1)
    expect(preview.text).not_to include("∑")
  end

  it "anchors a comment across authored HTML that imitates math" do
    source = "Before <span data-math-style=\"inline\">x</span> after the imitation.\n\nReal $y$ stays math.\n"
    imitation = CoPlan::Plans::Create.call(title: "Imitation", content: source, user: author,
      visibility: "published", actor_type: "human")
    visit plan_page_path(imitation)
    expect(page).to have_css("span[data-math-style].is-math-rendered .katex", count: 1, wait: 20)
    expect(page).to have_css("[data-math-style]", count: 1)

    select_across("Before", 0, " after", 6)
    comment_on_selection("Not actually math")

    thread = CoPlan::CommentThread.order(:created_at).last
    expect(thread.anchor_text).to eq("Before x after")
    expect(imitation.reload.current_content[thread.anchor_start...thread.anchor_end]).to eq("Before <span data-math-style=\"inline\">x</span> after")
    expect(page).to have_css("mark.anchor-highlight", text: "x")
  end

  it "renders math in a comment" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: author)
    create(:comment, comment_thread: thread, author_id: author.id, body_markdown: "Should this be $\\sqrt{2}$, not $1.41$?")
    visit plan_page_path(plan)
    expand_plan_section("plan-general-comments")
    within("#plan-general-comments") { click_button "Open discussion", enable_aria_label: true }

    popover = find(".thread-popover", visible: true)
    expect(popover).to have_css("span[data-math-style].is-math-rendered .katex", count: 2, wait: 20)
    expect(popover).to have_css(".katex .sqrt")
  end

  it "anchors a comment on text beside math, spanning the formula's source" do
    visit plan_page_path(plan)
    expect(page).to have_css("span[data-math-style].is-math-rendered", minimum: 2, wait: 20)

    select_across("relation", 0, " links", 6)
    comment_on_selection("Is the relation exact?")

    thread = CoPlan::CommentThread.order(:created_at).last
    expect(thread.anchor_text).to eq("relation links")
    expect(content[thread.anchor_start...thread.anchor_end]).to eq("relation $E = mc^2$ links")
    # Broadcasts can replace the marks between Selenium reads. Let Capybara
    # re-query them instead of holding element handles across that update.
    expect(page).to have_css("mark.anchor-highlight", count: 2)
    expect(page).to have_css("mark.anchor-highlight", exact_text: "relation", count: 1)
    expect(page).to have_css("mark.anchor-highlight", exact_text: "links", count: 1)
    expect(page).to have_no_css("[data-math-style] mark")
    expect(page).to have_css("span[data-math-style] .katex", count: 2)

    # The highlight survives a reload, with the formula still typeset.
    visit plan_page_path(plan)
    expect(page).to have_css("mark.anchor-highlight", text: "relation", wait: 20)
    expect(page).to have_css("span[data-math-style].is-math-rendered .katex", count: 2, wait: 20)
  end

  it "moves a selection that starts inside a formula to the text after it" do
    visit plan_page_path(plan)
    expect(page).to have_css("span[data-math-style='inline'].is-math-rendered", minimum: 1, wait: 20)

    select_across(nil, 0, " links mass", 11)
    comment_on_selection("Starts in math")

    thread = CoPlan::CommentThread.order(:created_at).last
    expect(thread.anchor_text).to eq("links mass")
    expect(content[thread.anchor_start...thread.anchor_end]).to eq("links mass")
  end

  it "offers no comment for a selection wholly inside a formula" do
    visit plan_page_path(plan)
    expect(page).to have_css("pre[data-math-style].is-math-rendered", wait: 20)

    page.execute_script(<<~JS)
      const math = document.querySelector('pre[data-math-style] .katex-html');
      const range = document.createRange(); range.selectNodeContents(math);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      math.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    JS
    page.driver.browser.action.send_keys("c").perform

    expect(page).to have_no_css(".comment-window:popover-open")
    expect(CoPlan::CommentThread.count).to eq(0)
  end
end
