require "rails_helper"

RSpec.describe "Rich views with dense content", type: :system do
  let(:user) { create(:coplan_user, email: "rich-views@example.com") }
  let(:content) { Rails.root.join("spec/fixtures/rich_views/prose-table.md").read }
  let(:plan) do
    create(:plan, created_by_user: user).tap do |plan|
      version = create(:plan_version, plan: plan, revision: 2, content_markdown: content)
      plan.update!(current_plan_version: version, current_revision: 2)
    end
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_page_path(plan)
    page.execute_script(<<~JS)
      window.richSubmissions = [];
      document.addEventListener('turbo:submit-end', event => {
        window.richSubmissions.push({success: event.detail.success, source: !!event.target.closest('.source-comments')});
      }, true);
    JS
  end

  after do |example|
    if example.exception
      warn page.evaluate_script(<<~JS)
        (() => {
          const root = document.querySelector('.plan-layout');
          const c = window.Stimulus.getControllerForElementAndIdentifier(root, 'coplan--source-comments');
          return JSON.stringify({submissions: window.richSubmissions, open: c.panelTarget.matches(':popover-open'),
            composing: c.composing, bodyPresent: !!c.bodyTarget.value, composerHidden: c.composerTarget.hidden,
            matchedThreads: c.selection && c.matchingThreads(c.selection).length,
            discussions: Array.from(c.discussionsTarget.children).map(el => ({text: el.textContent, display: getComputedStyle(el).display,
              html: el.innerHTML.replace(/value="[^"]*"/g, 'value="[omitted]"')}))});
        })()
      JS
      warn page.driver.browser.logs.get(:browser).map(&:message).join("\n")
    end
  end

  after { page.current_window.resize_to(1400, 900) }

  def expand_table
    find(".data-grid").hover
    find(".data-grid__expand").click
    expect(page).to have_css("dialog.expander[open]")
  end

  it "keeps the grid still while browsing and expands compact rows explicitly" do
    expand_table
    expect(page).to have_css(".data-sheet__frame.is-wrapped")
    expect(page).to have_no_css(".data-sheet__value", visible: :all)
    click_button "Wrap cell text"
    top = page.evaluate_script("document.querySelector('.data-sheet__table').getBoundingClientRect().top")
    find("td.is-cursor").send_keys(:end, :arrow_down)
    expect(page.evaluate_script("document.querySelector('.data-sheet__table').getBoundingClientRect().top")).to eq(top)
    expect(page).to have_no_css(".data-sheet__value", visible: :all)
    compact_height = find("td.is-cursor").evaluate_script("this.offsetHeight")
    find("td.is-cursor").send_keys("r")
    expect(page).to have_css("tr.is-expanded td.is-cursor")
    expect(find("td.is-cursor").evaluate_script("this.offsetHeight")).to be > compact_height
    expect(find("td.is-cursor").evaluate_script("this.scrollWidth <= this.clientWidth + 1 && this.scrollHeight <= this.clientHeight + 1")).to be(true)
    expect(page).to have_no_css(".source-comments", visible: true)
    find(".data-sheet__row-toggle").click
    expect(page).to have_no_css("tr.is-expanded")
    find(".data-sheet__row-toggle").click
    page.save_screenshot(Rails.root.join("tmp/rich-table-expanded-row.png"))
    click_button "Wrap cell text"
    expect(page).to have_no_css(".data-sheet__row-toggle", visible: true)
    page.save_screenshot(Rails.root.join("tmp/rich-table-prose-dark.png"))
    page.execute_script("document.documentElement.dataset.theme = 'light'")
    page.save_screenshot(Rails.root.join("tmp/rich-table-prose-light.png"))
  end

  it "keeps the comment command visible and the prose readable on a narrow viewport" do
    page.current_window.resize_to(500, 844)
    expand_table
    expect(page).to have_button("C Comment")
    expect(page).to have_no_css(".source-comment-prompt", visible: :all)
    expect(page.evaluate_script("document.querySelector('.expander__status').getBoundingClientRect().bottom <= innerHeight")).to be(true)
    page.save_screenshot(Rails.root.join("tmp/rich-table-prose-mobile.png"))
    find("td.is-cursor").send_keys(:end)
    find(".data-sheet__comment").click
    expect(page).to have_css(".source-comments textarea:focus")
  end

  it "attaches cell comments without repeating long content in the composer or discussion" do
    expand_table
    cell = all("dialog tbody tr")[2].all("td")[2]
    cell.click
    cell.send_keys("c")
    expect(page).to have_css("dialog td.is-source-selected")
    within(".source-comments") do
      expect(page).to have_no_css(".comment-form__anchor")
      expect(page).to have_no_text("The host adapts its existing catalog client")
      fill_in "Write a comment...", with: "Clarify this contract"
      click_button "Comment", exact: true
      expect(page).to have_text("Clarify this contract")
      expect(page).to have_no_css(".thread-popover__quote")
      expect(page).to have_no_text("The host adapts its existing catalog client")
    end
    expect(page.evaluate_script("document.querySelector('.source-comments').getBoundingClientRect().bottom <= innerHeight")).to be(true)
    page.save_screenshot(Rails.root.join("tmp/table-comment-without-duplicate.png"))
  end

  context "a large inventory" do
    let(:content) do
      header = [ "Mutation" ] + (1..23).map { |n| "Field #{n}" }
      rows = (1..120).map do |row|
        [ "`updateEntry#{row}(entryId, options)`" ] + (1..23).map { |col| "Value #{row}.#{col} with details" }
      end
      "# Wide inventory\n\n| #{header.join(' | ')} |\n|#{([ '---' ] * 24).join('|')}|\n" + rows.map { |row| "| #{row.join(' | ')} |" }.join("\n")
    end

    it "keeps a double-clicked far cell selected and visible after expansion" do
      cell = find(".data-grid td", text: "Value 110.22 with details", exact_text: true)
      cell.scroll_to(:center)
      cell.double_click
      expect(page).to have_css("dialog td.is-cursor:focus", text: "Value 110.22 with details", exact_text: true)
      expect(page).to have_css(".data-sheet__address", text: "W110", exact_text: true)
      expect(page.evaluate_script(<<~JS)).to be(true)
        (() => {
          const frame = document.querySelector('.data-sheet__frame').getBoundingClientRect();
          const cell = document.querySelector('td.is-cursor');
          const box = cell.getBoundingClientRect();
          const pinned = cell.parentElement.cells[0].getBoundingClientRect();
          const header = document.querySelector('.data-sheet__table thead').getBoundingClientRect();
          return box.left >= pinned.right - 1 && box.right <= frame.right + 1 && box.top >= header.bottom - 1 && box.bottom <= frame.bottom + 1;
        })()
      JS
      expect(page).to have_no_css(".source-comments", visible: true)
    end

    it "reaches every corner, preserves the pinned label, and comments on the exact far cell" do
      expand_table
      find("td.is-cursor").send_keys([ :shift, :end ])
      expect(page).to have_css(".data-sheet__address", text: "X120")
      bounds = page.evaluate_script(<<~JS)
        (() => {
          const frame = document.querySelector('.data-sheet__frame');
          const cell = document.querySelector('td.is-cursor');
          const box = cell.getBoundingClientRect();
          const viewport = frame.getBoundingClientRect();
          return {scrolled: frame.scrollLeft > 0 && frame.scrollTop > 0,
            visible: box.left >= viewport.left && box.right <= viewport.right + 1,
            pinned: getComputedStyle(cell.parentElement.cells[0]).position === 'sticky'};
        })()
      JS
      expect(bounds.values).to all(eq(true))
      find("td.is-cursor").send_keys("c")
      within(".source-comments") do
        fill_in "Write a comment...", with: "Check the far corner"
        click_button "Comment", exact: true
      end
      expect(page).to have_text("Check the far corner")
      expect(plan.comment_threads.last.anchor_text.strip).to eq("Value 120.23 with details")
      page.driver.browser.action.send_keys(:escape).perform
      find("td.is-cursor").send_keys([ :shift, :home ])
      expect(page).to have_css(".data-sheet__address", text: "A1")
      expect(page.evaluate_script("document.querySelector('.data-sheet__frame').scrollLeft")).to eq(0)
      page.save_screenshot(Rails.root.join("tmp/rich-table-wide.png"))
    end
  end

  context "the Mermaid gallery" do
    let(:content) { Rails.root.join("spec/fixtures/rich_views/mermaid-gallery.md").read }

    it "browses first, selects new shapes in comment mode, and offers honest whole-diagram comments for other families" do
      expect(page).to have_css(".mermaid-diagram__canvas svg", count: 8, wait: 45)
      diagrams = all(".mermaid-diagram")
      diagrams[1].find("g.node[data-source-target]", match: :first).double_click
      expect(page).to have_css("dialog.expander[open]")
      expect(page).to have_no_css(".source-comments", visible: true)
      find(".expander__title").hover
      find(".expander__canvas").send_keys("c")
      expect(page).to have_css("dialog.is-comment-mode .expander__canvas:focus")
      expect(page).to have_no_css("dialog g.node[data-source-target]:focus")
      expect(page.evaluate_script(<<~JS)).to be(true)
        Array.from(document.querySelectorAll('dialog .source-node-shape')).every(shape => getComputedStyle(shape).filter === 'none')
      JS
      page.driver.browser.action.send_keys(:tab).perform
      expect(page).to have_css("dialog svg [data-source-target]:focus")
      # SVG document order places connections before nodes. Continue through
      # those keyboard targets to explicitly choose the first node.
      all("dialog path.flowchart-link:not(.source-edge-hit)").length.times do
        break if page.has_css?("dialog g.node[data-source-target]:focus", wait: 0)
        page.driver.browser.action.send_keys(:tab).perform
      end
      find("dialog g.node[data-source-target]:focus").send_keys(:enter)
      expect(page).to have_css(".source-comments textarea:focus")
      within(".source-comments") do
        fill_in "Write a comment...", with: "Review the new document shape"
        click_button "Comment", exact: true
      end
      expect(page).to have_text("Review the new document shape")
      expect(plan.comment_threads.last.anchor_text).to include('Request@{ shape: doc')
      page.driver.browser.action.send_keys(:escape).perform
      expect(page).to have_css("dialog.is-comment-mode")
      page.driver.browser.action.send_keys(:escape).perform
      expect(page).to have_css("dialog.expander[open]:not(.is-comment-mode)")
      find('dialog [aria-label="Close"]').click

      diagrams[2].send_keys("c")
      expect(diagrams[2]).to have_text("Whole-diagram comments available")
      diagrams[2].find(".mermaid-diagram__canvas").click(x: 10, y: 10)
      expect(page).to have_css(".source-comments textarea:focus")
      within(".source-comments") do
        expect(page).to have_css(".comment-form__quote", text: "Entire diagram")
        fill_in "Write a comment...", with: "Review this sequence"
        click_button "Comment", exact: true
      end
      expect(page).to have_text("Review this sequence")
      expect(plan.comment_threads.order(:created_at).last).to have_attributes(anchor_kind: "mermaid_diagram")
      within(".source-comments") { click_button "Resolve (e)" }
      expect(page).to have_no_css(".source-comments:popover-open")
      diagrams[2].send_keys("c")
      expect(diagrams[2]).to have_no_button("Comment on whole diagram")
      find("body").send_keys("s")
      diagrams[2].click_button "Comment on whole diagram"
      within(".source-comments") do
        expect(page).to have_text("Review this sequence")
        click_button "Reopen"
      end
      visit plan_page_path(plan)
      expect(page).to have_css(".mermaid-diagram__canvas svg", count: 8, wait: 45)
      all(".mermaid-diagram")[2].click_button "Comment on whole diagram"
      expect(page).to have_css(".source-comments", text: "Review this sequence")
    end

    it "renders all eight diagram families/examples and expands each with working zoom" do
      expect(page).to have_css(".mermaid-diagram__canvas svg", count: 8, wait: 45)
      expect(page).to have_no_css(".mermaid-diagram--error")
      expect(all(".mermaid-diagram")[1]).to have_css("g.node[data-source-target]", count: 6)
      expect(all(".mermaid-diagram")[0]).to have_css("g.node[data-source-target]", count: 16)
      all(".mermaid-diagram").each_with_index do |diagram, index|
        diagram.hover
        diagram.find(".mermaid-diagram__expand").click
        expect(page).to have_css(".expander__canvas svg")
        authored_styles = page.evaluate_script(<<~JS)
          Array.from(document.querySelectorAll('dialog .source-node-shape')).map(shape => {
            const style = getComputedStyle(shape);
            return [style.stroke, style.strokeWidth, style.strokeDasharray, style.filter];
          })
        JS
        find("dialog .diagram-comments__toggle").click
        expect(page).to have_css("dialog.is-comment-mode")
        if index < 2
          expect(page.evaluate_script(<<~JS)).to be(true)
            Array.from(document.querySelectorAll('dialog g.node[data-source-target]')).every(node => {
              const shapes = Array.from(node.querySelectorAll('.source-node-shape'));
              return shapes.length > 0;
            })
          JS
          expect(page.evaluate_script(<<~JS)).to eq(authored_styles)
            Array.from(document.querySelectorAll('dialog .source-node-shape')).map(shape => {
              const style = getComputedStyle(shape);
              return [style.stroke, style.strokeWidth, style.strokeDasharray, style.filter];
            })
          JS
        else
          expect(page).to have_css("dialog.is-whole-diagram-comment")
        end
        click_button "Fit to screen"
        expect(page.evaluate_script(<<~JS)).to be(true)
          (() => {
            const canvas = document.querySelector('.expander__canvas').getBoundingClientRect();
            const svg = document.querySelector('.expander__canvas > svg').getBoundingClientRect();
            return svg.left >= canvas.left && svg.top >= canvas.top && svg.right <= canvas.right + 1 && svg.bottom <= canvas.bottom + 1;
          })()
        JS
        page.save_screenshot(Rails.root.join("tmp/mermaid-fit-comment-#{index}.png"))
        before = find(".expander__readout").text.to_i
        click_button "Zoom in"
        expect(find(".expander__readout").text.to_i).to be > before
        page.save_screenshot(Rails.root.join("tmp/mermaid-stress-#{index}.png"))
        find('dialog [aria-label="Close"]').click
      end
      page.execute_script("document.documentElement.dataset.theme = 'light'; window.dispatchEvent(new Event('coplan:theme-changed'))")
      expect(page).to have_css('.mermaid-diagram[data-mermaid-theme="light"] .mermaid-diagram__canvas > svg', count: 8, wait: 45)
      expect(page).to have_no_css(".mermaid-diagram--error")
    end
  end
end
