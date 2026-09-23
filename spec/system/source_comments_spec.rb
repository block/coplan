require "rails_helper"

RSpec.describe "Source-backed diagram and table comments", type: :system do
  let(:user) { create(:coplan_user, email: "source-comments@example.com") }
  let(:content) do
    <<~MARKDOWN
      # Source selections

      ```mermaid
      flowchart LR
        A[Same] --> B[Same]
        A --> B
        B -->|next| C[End]
      ```

      | Name | Value | Link | Extra | Last |
      |---|---|---|---|---|
      | Second | same | [Example](https://example.com) | x | x |
      | First | same | plain | x | x |
      | Empty || plain | x | x |
    MARKDOWN
  end
  let(:plan) do
    CoPlan::Plan.create!(title: "Source selections", created_by_user: user).tap do |p|
      version = create(:plan_version, plan: p, revision: 1, content_markdown: content)
      p.update!(current_plan_version: version, current_revision: 1)
    end
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")
    visit plan_page_path(plan)
    expect(page).to have_css(".data-grid tbody tr", count: 3)
  end

  after { page.current_window.resize_to(1400, 900) }

  def panel
    find(".source-comments", visible: true)
  end

  def comment(body)
    panel.fill_in "Write a comment...", with: body
    panel.click_button "Comment", exact: true
    expect(panel).to have_text(body)
    expect(panel).to have_no_field("Write a comment...")
  end

  it "keeps browsing neutral and glows only hovered comment targets with a consistent cursor" do
    expect(page).to have_css(".mermaid-diagram g.node[data-source-target]", count: 3, wait: 20)
    shape_style = ->(element) { element.evaluate_script("[getComputedStyle(this).strokeWidth, getComputedStyle(this).strokeDasharray, getComputedStyle(this).filter]") }
    cursor = ->(element) { element.evaluate_script("getComputedStyle(this).cursor") }
    node = all(".mermaid-diagram g.node[data-source-target]")[1]
    shape = node.find(".source-node-shape")
    baseline = shape_style.call(shape)
    expect(page).to have_no_css(".mermaid-diagram .diagram-comments__toggle")
    expect(page).to have_no_css(".mermaid-diagram > .diagram-comments")
    node.hover
    expect(shape_style.call(shape)).to eq(baseline)
    expect(cursor.call(node)).to eq("default")
    expect(cursor.call(node.find(".nodeLabel"))).to eq("default")

    # Choose an actual point on the stroke, rather than the curved path's bounding-box center.
    edge = all(".mermaid-diagram path.flowchart-link:not(.source-edge-hit)").last
    hover_edge = lambda do
      offset = edge.evaluate_script(<<~JS)
        (() => {
        const p = this.getPointAtLength(this.getTotalLength() * 0.25);
        const screen = new DOMPoint(p.x, p.y).matrixTransform(this.getScreenCTM());
        const box = this.getBoundingClientRect();
        return [screen.x - (box.left + box.width / 2), screen.y - (box.top + box.height / 2)];
        })()
      JS
      page.driver.browser.action.move_to(edge.native, offset[0].round, offset[1].round).perform
    end
    edge_baseline = shape_style.call(edge)
    hover_edge.call
    expect(shape_style.call(edge)).to eq(edge_baseline)
    expect(cursor.call(edge)).to eq("default")

    find("#plan-header").hover
    find(".mermaid-diagram").send_keys("c")
    expect(page).to have_css(".mermaid-diagram.is-comment-mode:focus")
    expect(page).to have_no_css(".mermaid-diagram g.node:focus")
    expect(page.evaluate_script("Array.from(document.querySelectorAll('.mermaid-diagram .source-node-shape')).every(shape => getComputedStyle(shape).filter === 'none')")).to be(true)
    expect(shape_style.call(shape)).to eq(baseline)
    expect(shape_style.call(edge)).to eq(edge_baseline)
    node.hover
    expect(shape_style.call(shape).last).to include("drop-shadow")
    expect(shape_style.call(shape).first(2)).to eq(baseline.first(2))
    expect(cursor.call(node)).to include("data:image/svg+xml")
    expect(cursor.call(node.find(".nodeLabel"))).to eq(cursor.call(node))
    hover_edge.call
    expect(shape_style.call(edge).last).to include("drop-shadow")
    expect(shape_style.call(edge).first(2)).to eq(edge_baseline.first(2))
    expect(shape_style.call(shape)).to eq(baseline)
    page.save_screenshot(Rails.root.join("tmp/mermaid-hover-glow.png"))

    find(".mermaid-diagram").send_keys(:escape)
    hover_edge.call
    expect(shape_style.call(edge)).to eq(edge_baseline)
    node.double_click
    expect(page).to have_css("dialog.expander--diagram")
    expanded_node = all("dialog g.node[data-source-target]")[1]
    expanded_node.hover
    expect(cursor.call(expanded_node)).to eq("grab")
    expect(cursor.call(expanded_node.find(".nodeLabel"))).to eq("grab")
    page.execute_script(<<~JS)
      const range = document.createRange();
      range.selectNodeContents(document.querySelector('dialog .nodeLabel'));
      getSelection().removeAllRanges();
      getSelection().addRange(range);
    JS
    expect(page.evaluate_script("getSelection().isCollapsed")).to be(false)
    find(".expander__canvas").send_keys("c")
    expect(page.evaluate_script("getSelection().isCollapsed")).to be(true)
    expanded_node.hover
    expect(cursor.call(expanded_node)).to include("data:image/svg+xml")
    expect(shape_style.call(expanded_node.find(".source-node-shape")).last).to include("drop-shadow")
    expanded_node.click
    expect(panel).to have_css("textarea:focus")
  end

  it "comments through connection labels and keeps badges visible and panels attached through replies and resolution" do
    expect(page).to have_css(".mermaid-diagram .source-edge-label", text: "next", wait: 20)
    [ false, true ].each do |expanded|
      if expanded
        find(".mermaid-diagram").hover
        find(".mermaid-diagram__expand").click
      end
      scope = expanded ? "dialog.expander" : ".mermaid-diagram"
      find(expanded ? ".expander__canvas" : scope).send_keys("c")
      label = find("#{scope} .source-edge-label", text: "next")
      label.hover
      expect(label.find("p").evaluate_script("getComputedStyle(this).cursor")).to include("data:image/svg+xml")
      label.click
      expect(panel).to have_css("textarea:focus")
      comment("Discuss the labeled arrow #{expanded}")
      expect(plan.comment_threads.order(:created_at).last.anchor_text).to eq("B -->|next| C[End]")
      panel.find('[aria-label="Close element comments"]').click
      find(expanded ? ".expander__canvas" : scope).send_keys(:escape)
      badge = find("#{scope} .source-edge-badges .anchor-highlight--open")
      badge.scroll_to(:center)
      expect(badge.evaluate_script(<<~JS)).to be(true)
        (() => {
          const b = this.getBoundingClientRect();
          return this.contains(document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2));
        })()
      JS
      badge.click
      expect(panel).to have_text("Discuss the labeled arrow #{expanded}")
      top_before = panel.evaluate_script("this.getBoundingClientRect().top")
      panel.find('textarea[name="comment[body_markdown]"]').set("A reply keeps this attached")
      panel.click_button "Reply", exact: true
      expect(panel).to have_text("A reply keeps this attached")
      expect(panel.evaluate_script("this.getBoundingClientRect().top")).to be > 16
      expect(panel.evaluate_script("this.getBoundingClientRect().top")).to be_within(200).of(top_before)
      page.save_screenshot(Rails.root.join("tmp/connection-comment-#{expanded}.png"))
      panel.click_button "Resolve (e)"
      expect(page).to have_no_css(".source-comments", visible: true)
      expect(page).to have_no_css("#{scope} .source-edge-badges .anchor-highlight--open")
      find('dialog [aria-label="Close"]').click if expanded
    end
  end

  it "selects duplicate nodes and individual parallel unlabeled connections in either view" do
    expect(page).to have_css(".mermaid-diagram svg", wait: 20)
    expect(page).to have_css(".mermaid-diagram g.node[data-source-target]", count: 3, wait: 20)
    nodes = all(".mermaid-diagram g.node[data-source-target]")
    find(".mermaid-diagram").send_keys("c")
    nodes[1].click
    expect(panel).to have_css('textarea[placeholder="Write a comment..."]:focus')
    expect(panel).to have_css(".comment-form__quote", text: "Same")
    comment("Change the second Same")
    expect(plan.comment_threads.last.anchor_text).to eq("B[Same]")
    panel.click_button "New comment", exact: true
    expect(panel).to have_field("Write a comment...")
    expect(panel).to have_button("Cancel")
    panel.find('[aria-label="Close element comments"]').click

    find(".mermaid-diagram").hover
    find(".mermaid-diagram__expand").click
    expect(page).to have_css("dialog.expander[open]")
    find(".expander__canvas").send_keys("c")
    find("dialog g.node[data-source-target]", text: "Same", match: :first).click
    expect(panel).to have_css(".comment-form__quote", text: "Same")
    panel.find('[aria-label="Close element comments"]').click
    # The transparent hit path is the intended generous click/tap target.
    paths = all("dialog path.source-edge-hit")
    expect(paths.length).to eq(3)
    # Selenium's center-of-bounding-box click need not lie on a curved SVG
    # stroke, so activate the actual keyboard target for this connection.
    edges = all("dialog path.flowchart-link[data-source-target]:not(.source-edge-hit)")
    edges[1].send_keys(:enter)
    expect(panel).to have_text("Connection A → B")
    comment("Review the parallel connection")
    page.save_screenshot(Rails.root.join("tmp/source-comments-desktop.png"))
    expect(plan.comment_threads.order(:created_at).last.anchor_text).to eq("A --> B")
    expect(plan.comment_threads.order(:created_at).last.anchor_kind).to eq("mermaid_edge")
    panel.find('[aria-label="Close element comments"]').click
    find('dialog [aria-label="Close"]').click
    expect(page).to have_css(".mermaid-diagram .source-thread-badge", count: 2)
    visit plan_page_path(plan)
    expect(page).to have_css(".mermaid-diagram .source-thread-badge", count: 2, wait: 20)
    find(".mermaid-diagram g.node .source-thread-badge").click
    expect(panel).to have_text("Change the second Same")
    expect(page).to have_no_css("dialog.expander[open]")
  end

  it "keeps table source identity through sorting and supports an empty cell" do
    rows = all(".data-grid tbody tr")
    rows[1].all("td")[1].send_keys("c")
    expect(panel).to have_no_text(/Row \d+, column \d+/)
    comment("Only the second same")
    thread = plan.comment_threads.last
    expect(thread.anchor_start).to eq(content.index(" same ", content.index(" same ") + 1))
    panel.find('[aria-label="Close element comments"]').click

    find(".data-grid").hover
    find(".data-grid__expand").click
    find('dialog [aria-label="Sort by Name"]').click
    find("dialog tbody tr", text: "First").all("td")[1].send_keys("c")
    expect(panel).to have_no_text(/Row \d+, column \d+/)
    expect(panel).to have_text("Only the second same")
    panel.find('[aria-label="Close element comments"]').click
    find("dialog tbody tr", text: "Empty").all("td")[1].send_keys("c")
    comment("Fill this blank")
    expect(plan.comment_threads.order(:created_at).last.anchor_text).to eq("||")
    resolved_thread = plan.comment_threads.order(:created_at).last
    panel.click_button "Resolve (e)"
    expect(page).to have_no_css(".source-comments", visible: true)
    visit plan_page_path(plan, thread: resolved_thread.id)
    expect(panel).to have_button("Reopen")
    panel.click_button "Reopen"
    expect(panel).to have_button("Resolve (e)")
    panel.find('[aria-label="Close element comments"]').send_keys("r")
    expect(page.evaluate_script("document.activeElement.name")).to eq("comment[body_markdown]")
    panel.find('textarea[name="comment[body_markdown]"]').set("Reply to the empty cell")
    panel.click_button "Reply", exact: true
    expect(panel).to have_text("Reply to the empty cell")
    expect(panel.find('textarea[name="comment[body_markdown]"]').value).to eq("")
  end

  it "offers a reachable mobile sheet and retains drafts when switching targets" do
    page.current_window.resize_to(390, 844)
    cells = all(".data-grid tbody tr").first.all("td")
    cells[0].send_keys("c")
    panel.fill_in "Write a comment...", with: "Keep my draft"
    panel.find('[aria-label="Close element comments"]').click
    cells[1].send_keys("c")
    expect(panel).to have_field("Write a comment...", with: "")
    panel.find('[aria-label="Close element comments"]').click
    cells[0].send_keys("c")
    expect(panel).to have_field("Write a comment...", with: "Keep my draft")
    geometry = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector('.source-comments').getBoundingClientRect();
      return { left: r.left, right: r.right, bottom: r.bottom, width: innerWidth, height: innerHeight }; })()
    JS
    expect(geometry["left"]).to be >= 0
    expect(geometry["right"]).to be <= geometry["width"]
    expect(geometry["bottom"]).to be <= geometry["height"]
    comment("Posted from a phone")
    sheet = page.evaluate_script("(() => {const r=document.querySelector('.source-comments').getBoundingClientRect(); return {width:r.width,bottom:r.bottom,viewportWidth:document.documentElement.clientWidth,viewportHeight:innerHeight};})()")
    expect(sheet["width"]).to be_within(1).of(sheet["viewportWidth"])
    expect(sheet["bottom"]).to be_within(1).of(sheet["viewportHeight"])
    page.save_screenshot(Rails.root.join("tmp/source-comments-mobile.png"))
  end
  it "keeps changed targets accessible with their original source and an out-of-date label" do
    all(".data-grid tbody tr")[1].all("td")[1].send_keys("c")
    comment("Keep this discussion")
    thread = plan.comment_threads.last
    edited = content.dup
    edited[thread.anchor_start...thread.anchor_end] = " changed "
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: edited, base_revision: 1,
      actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)
    click_button "Outdated element comments (1)"
    expect(panel).to have_text("Keep this discussion")
    expect(panel).to have_text(/out of date/i)
    expect(panel).to have_css(".thread-popover__quote", text: "same")
    expect(panel).to have_no_field("Write a comment...")
    panel.click_button "Resolve (e)"
    expect(page).to have_no_css(".source-comments", visible: true)
    visit plan_page_path(plan, thread: thread.id)
    expect(panel).to have_text("Keep this discussion")
    expect(panel).to have_text(/out of date/i)
  end

  it "preserves a draft after a stale selection is rejected" do
    all(".data-grid tbody tr")[1].all("td")[1].send_keys("c")
    panel.fill_in "Write a comment...", with: "Keep this stale draft"
    # Leave this browser on its displayed revision, as if cable disconnected.
    allow(CoPlan::Broadcaster).to receive(:replace_plan_content)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Preface\n\n#{content}", base_revision: 1,
      actor_type: "human", actor_id: user.id)
    panel.click_button "Comment", exact: true
    expect(panel).to have_text("selection is no longer valid")
    expect(panel).to have_field("Write a comment...", with: "Keep this stale draft")
    expect(plan.comment_threads.count).to eq(0)
  end

  it "supports keyboard selection and Escape without closing the expanded table" do
    all(".data-grid tbody tr")[1].all("td")[1].send_keys(:enter)
    expect(panel).to have_css('textarea[placeholder="Write a comment..."]:focus')
    page.driver.browser.action.send_keys("A keyboard-only draft").perform
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_no_css(".source-comments", visible: true)
    find(".data-grid").hover
    find(".data-grid__expand").click
    cell = all("dialog tbody tr")[1].all("td")[1]
    cell.send_keys(:enter)
    expect(panel).to have_no_text(/Row \d+, column \d+/)
    expect(panel).to have_css('textarea[placeholder="Write a comment..."]:focus')
    expect(panel).to have_field("Write a comment...", with: "A keyboard-only draft")
    comment("Posted with keyboard selection")
    page.driver.browser.action.send_keys(:escape).perform
    cell.send_keys(:enter)
    expect(panel).to have_css('.thread-popover__reply textarea:focus')
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_no_css(".source-comments", visible: true)
    expect(page).to have_css("dialog.expander[open]")
    expect(page.evaluate_script("document.activeElement.matches('td[data-source-target]')")).to be(true)
  end

  it "navigates source discussions through the shared panel in the active table and keeps reply drafts" do
    cells = all(".data-grid tbody tr").map { |row| row.all("td")[1] }
    cells[0].send_keys("c")
    comment("First cell discussion")
    page.driver.browser.action.send_keys(:escape).perform
    cells[1].send_keys("c")
    comment("Second cell discussion")
    page.driver.browser.action.send_keys(:escape).perform

    find("body").send_keys("j")
    expect(panel).to have_text("First cell discussion")
    panel.fill_in "Press r to reply", with: "Keep my navigation draft"
    panel.find('[aria-label="Close element comments"]').send_keys("j")
    expect(panel).to have_text("Second cell discussion")
    page.driver.browser.action.send_keys(:escape).perform

    find(".data-grid").hover
    find(".data-grid__expand").click
    find("td.is-cursor").send_keys("j")
    expect(page).to have_css("dialog .source-comments:popover-open", text: "First cell discussion")
    expect(panel).to have_field("Press r to reply", with: "Keep my navigation draft")
    expect(page).to have_css("dialog td.is-source-selected", count: 1)
    expect(page).to have_no_css("#plan-threads .thread-popover:popover-open")

    # A nested scroller must reposition the shared panel, not a legacy popover.
    page.execute_script("const frame = document.querySelector('.data-sheet__frame'); frame.style.flex = 'none'; frame.style.height = '90px'")
    top = panel.evaluate_script("this.getBoundingClientRect().top")
    page.execute_script("document.querySelector('.data-sheet__frame').scrollTop = 20")
    expect(page).to have_css('.source-comments:popover-open')
    expect(page).to have_css(".source-comments:popover-open") { |element| element.evaluate_script("this.getBoundingClientRect().top") < top }
    panel.find('[aria-label="Close element comments"]').send_keys("j")
    expect(panel).to have_text("Second cell discussion")
    expect(page).to have_css("dialog td.is-source-selected", count: 1)
  end

  it "clears the cell selection when navigating to prose and preserves its reply draft" do
    prose = create(:comment_thread, plan: plan, created_by_user: user, anchor_text: "Source selections")
    create(:comment, comment_thread: prose, author_id: user.id, body_markdown: "A prose discussion")
    visit plan_page_path(plan)
    all(".data-grid tbody tr")[1].all("td")[1].send_keys("c")
    comment("A cell discussion")
    page.driver.browser.action.send_keys(:escape).perform

    find("body").send_keys("j")
    expect(page).to have_css("#plan-threads .thread-popover:popover-open", text: "A prose discussion")
    find("body").send_keys("j")
    expect(panel).to have_text("A cell discussion")
    panel.fill_in "Press r to reply", with: "Keep this mixed-navigation draft"
    panel.find('[aria-label="Close element comments"]').send_keys("k")
    expect(page).to have_css("#plan-threads .thread-popover:popover-open", text: "A prose discussion")
    expect(page).to have_no_css(".source-comments:popover-open")
    expect(page).to have_no_css(".is-source-selected")
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_no_css(".is-source-selected")

    find("body").send_keys("j")
    expect(panel).to have_text("A cell discussion")
    expect(panel).to have_field("Press r to reply", with: "Keep this mixed-navigation draft")
  end

  it "dismisses outside clicks and keeps drafts in the document and expanded table" do
    cell = all(".data-grid tbody tr")[1].all("td")[1]
    cell.send_keys("c")
    panel.fill_in "Write a comment...", with: "Keep this draft"
    find("#plan-header").click
    expect(page).to have_no_css(".source-comments", visible: true)
    expect(page).to have_no_css(".is-source-selected")

    find(".data-grid").hover
    find(".data-grid__expand").click
    cell = all("dialog tbody tr")[1].all("td")[1]
    cell.send_keys("c")
    expect(panel).to have_field("Write a comment...", with: "Keep this draft")
    frame = find("dialog .data-sheet__frame")
    frame.click(x: 0, y: frame.evaluate_script("this.clientHeight") / 2 - 10)
    expect(page).to have_no_css(".source-comments", visible: true)
    expect(page).to have_css("dialog.expander[open]")
    expect(page).to have_no_css(".is-source-selected")

    cell.send_keys("c")
    expect(panel).to have_field("Write a comment...", with: "Keep this draft")
    comment("A discussion to revisit")
    panel.find('textarea[name="comment[body_markdown]"]').set("Keep this reply")
    frame.click(x: 0, y: frame.evaluate_script("this.clientHeight") / 2 - 10)
    expect(page).to have_no_css(".source-comments", visible: true)
    cell.send_keys("c")
    expect(panel).to have_field("comment[body_markdown]", with: "Keep this reply")
    page.save_screenshot(Rails.root.join("tmp/source-comments-muted-badge.png"))
    # Another cell can open its own composer with the shortcut.
    all("dialog tbody tr").last.all("td").last.send_keys("c")
    expect(panel).to have_no_css(".comment-form__anchor")
    expect(panel).to have_field("Write a comment...", with: "")
  end

  it "browses cells without opening a composer and offers deliberate comment actions" do
    cell = all(".data-grid tbody tr").first.all("td")[1]
    cell.click
    expect(page).to have_no_css(".source-comments", visible: true)
    expect(page).to have_no_css(".source-comment-prompt", visible: :all)
    expect(cell).to match_css(":focus")
    cell.send_keys("c")
    expect(panel).to have_css('textarea[placeholder="Write a comment..."]:focus')
    comment("A discussion worth opening")
    page.driver.browser.action.send_keys(:escape).perform
    cell.click
    expect(page).to have_no_css(".source-comments", visible: true)
    cell.find(".source-thread-badge").click
    expect(panel).to have_css(".thread-popover__reply textarea:focus")
    page.driver.browser.action.send_keys(:escape).perform

    find(".data-grid").hover
    find(".data-grid__expand").click
    cell = all("dialog tbody tr").first.all("td")[1]
    cell.click
    expect(page).to have_no_css(".source-comments", visible: true)
    cell.send_keys(:arrow_right)
    expect(page).to have_no_css(".source-comments", visible: true)
    expect(page).to have_css('dialog td.is-source-browsing:focus', text: "Example")
    find(".data-sheet__comment").click
    expect(panel).to have_css('textarea[placeholder="Write a comment..."]:focus')
    expect(panel).to have_no_css(".comment-form__anchor")
    page.driver.browser.action.send_keys(:escape).perform
    all("dialog thead th").first.click
    find(".data-sheet__comment").click
    expect(panel).to have_no_css(".comment-form__anchor")
    page.driver.browser.action.send_keys(:escape).perform
    cell.find(".source-thread-badge").click
    expect(panel).to have_css(".thread-popover__reply textarea:focus")
  end

  it "refreshes posted replies while keeping another discussion's draft and form alive" do
    all(".data-grid tbody tr")[1].all("td")[1].send_keys("c")
    comment("First discussion")
    panel.click_button "New comment"
    comment("Second discussion")
    threads = panel.all(".source-comments__discussion")
    threads[0].fill_in "Press r to reply", with: "Unsent first reply"
    threads[1].fill_in "Press r to reply", with: "Posted second reply"
    threads[1].find("textarea").send_keys(:enter)
    expect(panel).to have_text("Posted second reply")
    expect(panel.all(".source-comments__discussion")[0]).to have_field("Press r to reply", with: "Unsent first reply")
    expect(panel.all(".source-comments__discussion")[1]).to have_field("Press r to reply", with: "")
    expect(plan.comment_threads.joins(:comments).where(coplan_comments: { body_markdown: "Posted second reply" }).count).to eq(1)
  end

  it "opens comments on linked diagram nodes without following their links in comment mode" do
    expect(page).to have_css(".mermaid-diagram g.node[data-source-target]", count: 3, wait: 20)
    # Strict Mermaid rendering strips authored links. Exercise the same DOM
    # contract for renderers that retain links without relaxing that policy.
    page.execute_script(<<~JS)
      const node = document.querySelector('.mermaid-diagram g.node[data-source-target]');
      const link = document.createElementNS('http://www.w3.org/2000/svg', 'a');
      link.setAttribute('href', '#linked-detail');
      link.append(...node.childNodes);
      node.append(link);
    JS
    diagram = find(".mermaid-diagram")
    link = diagram.find('svg a[href="#linked-detail"]')
    link.click
    expect(page.evaluate_script("location.hash")).to eq("#linked-detail")
    expect(page).to have_no_css(".source-comments:popover-open")
    page.execute_script('history.replaceState(null, "", location.pathname)')
    diagram.send_keys("c")
    link.click
    expect(panel).to have_field("Write a comment...")
    expect(panel).to have_css("textarea:focus")
    expect(page.evaluate_script("location.hash")).to eq("")
    comment("Discuss the linked node")
    expect(plan.comment_threads.last.anchor_kind).to eq("mermaid_node")
  end

  it "keeps Markdown links interactive instead of selecting their cell" do
    link = find(".data-grid a", text: "Example")
    expect(link[:target]).to eq("_blank")
    # Prevent actual external navigation while exercising the click handlers.
    page.execute_script("document.querySelector('.data-grid a').addEventListener('click', e => e.preventDefault(), {once: true})")
    link.click
    expect(page).to have_no_css(".source-comments", visible: true)
  end

  it "pans from a node without treating the drag as a selection" do
    expect(page).to have_css(".mermaid-diagram g.node[data-source-target]", count: 3, wait: 20)
    find(".mermaid-diagram").hover
    find(".mermaid-diagram__expand").click
    node = all("dialog g.node[data-source-target]").first
    page.driver.browser.action.move_to(node.native).click_and_hold.move_by(60, 40).release.perform
    expect(page).to have_no_css(".source-comments", visible: true)
    expect(page).to have_css("dialog.expander[open]")
    # Comment mode makes a subsequent tap an intentional comment action.
    find(".expander__canvas").send_keys("c")
    node.click
    expect(panel).to have_css(".comment-form__quote", text: "Same")
  end
  it "reveals resolved cell discussions with S in both reading and expanded views" do
    cell = all(".data-grid tbody tr")[1].all("td")[1]
    cell.send_keys("c")
    comment("Resolved cell to revisit")
    panel.click_button "Resolve (e)"
    expect(cell).to have_no_css(".source-thread-badge")
    find("body").send_keys("s")
    cell.find(".source-thread-badge.anchor-highlight--resolved").click
    expect(panel).to have_text("Resolved cell to revisit")
    expect(panel).to have_button("Reopen")
    page.driver.browser.action.send_keys(:escape).perform

    find(".data-grid").hover
    find(".data-grid__expand").click
    find("td.is-cursor").send_keys("s")
    expect(page).to have_no_css("dialog .source-thread-badge")
    find("td.is-cursor").send_keys("s")
    find("dialog .source-thread-badge.anchor-highlight--resolved").click
    expect(panel).to have_text("Resolved cell to revisit")
    panel.click_button "Reopen"
    expect(panel).to have_button("Resolve (e)")
  end

  it "opens a resolved source thread from its permalink even though its badge is hidden" do
    all(".data-grid tbody tr")[1].all("td")[1].send_keys("c")
    comment("A resolved source discussion")
    thread = plan.comment_threads.last
    panel.click_button "Resolve (e)"
    expect(page).to have_no_css(".source-comments", visible: true)
    visit plan_page_path(plan, thread: thread.id)
    expect(panel).to have_text("A resolved source discussion")
    expect(panel).to have_no_text(/Row \d+, column \d+/)
    expect(panel).to have_button("Reopen")
  end
end
