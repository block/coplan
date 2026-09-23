require "rails_helper"

# A markdown table in a plan, in both of its forms: the framed, compact one
# that sits in the document, and the spreadsheet it expands into.
RSpec.describe "Data tables", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }

  let(:plan_content) do
    <<~MARKDOWN
      # Rollout

      ## Phases

      | Phase | Owner | Region | Traffic | Latency | Notes |
      |---|---|---|---|---|---|
      | Pilot | sam | us-east | 2% | 180ms | Internal merchants only, behind the flag |
      | Ramp | kim | us-west | 25% | 165ms | Waiting on the ledger backfill to finish |
      | Wide | ada | eu-central | 60% | 210ms | Needs a second region before it can go on |
      | Full | lee | global | 100% | 150ms | Flag removed, config baked in |
      | Hold | raj | ap-south | 0% | 195ms | Paused pending a compliance review |
      | Sunset | tom | us-east | 0% | 172ms | Old path retired after two clean weeks |
      | Audit | joe | global | 5% | 188ms | Sampled traffic for the quarterly review |
      | Repair | pat | us-west | 10% | 205ms | Retry path rebuilt, watching error rates |
      | Verify | nia | eu-central | 40% | 169ms | Shadow reads compared against the legacy |

      The table above is the plan of record.
    MARKDOWN
  end

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Rollout Plan", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: plan_content, actor_type: "human", actor_id: author.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")
  end

  # The affordance only shows on hover, so a click has to be preceded by
  # one — and the controller only offers it once it has measured the table.
  def open_spreadsheet
    expect(page).to have_css(".data-grid.is-expandable")
    find(".data-grid").hover
    find(".data-grid__expand").click
    expect(page).to have_css(".expander--grid .data-sheet__table")
  end

  def computed(selector, property)
    page.evaluate_script(
      "getComputedStyle(document.querySelector(#{selector.to_json})).#{property}"
    )
  end

  def frame_overflows?
    page.evaluate_script(<<~JS)
      (() => {
        const frame = document.querySelector(".data-grid__frame")
        return frame.scrollWidth - frame.clientWidth > 1
      })()
    JS
  end

  # Sixteen columns of unbreakable tokens: no amount of wrapping saves this
  # one, so it has to scroll.
  let(:wide_plan) do
    header = (1..16).map { |n| "Column#{n}" }
    row = (1..16).map { |n| "value-#{n}-unbreakable" }
    markdown = [
      "# Wide", "",
      "| #{header.join(' | ')} |",
      "|#{([ '---' ] * 16).join('|')}|",
      "| #{row.join(' | ')} |", ""
    ].join("\n")

    p = CoPlan::Plan.create!(title: "Wide Plan", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: markdown, actor_type: "human", actor_id: author.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  before { sign_in(author) }

  it "expands a cell on double-click while a single click keeps browsing inline" do
    visit plan_page_path(plan)
    cell = find(".data-grid td", text: "Pilot", exact_text: true)
    cell.click
    expect(page).to have_no_css("dialog.expander")
    cell.double_click
    expect(page).to have_css("dialog.expander--grid td.is-cursor:focus", text: "Pilot", exact_text: true)
    expect(page).to have_no_css(".source-comments", visible: true)
  end

  it "preserves a double-clicked header without sorting or selecting a body cell" do
    visit plan_page_path(wide_plan)
    header = find(".data-grid th", text: "Column16", exact_text: true)
    header.scroll_to(:center)
    header.double_click
    expect(page).to have_css("dialog th.is-cursor:focus[aria-sort='none']", text: "Column16")
    expect(page).to have_no_css("dialog td.is-cursor")
    expect(page.evaluate_script(<<~JS)).to be(true)
      (() => {
        const box = document.querySelector('dialog th.is-cursor').getBoundingClientRect();
        const frame = document.querySelector('.data-sheet__frame').getBoundingClientRect();
        return box.left >= frame.left && box.right <= frame.right + 1;
      })()
    JS
    find("dialog th.is-cursor").send_keys(:arrow_down)
    expect(page).to have_css("dialog td.is-cursor", text: "value-16-unbreakable")
  end

  describe "in the document" do
    it "wraps long cells so a realistic table fits the column" do
      visit plan_page_path(plan)

      expect(page).to have_css(".data-grid__frame table")
      expect(computed(".data-grid__frame", "overflowX")).to eq("auto")
      expect(frame_overflows?).to be(false)
      expect(page).to have_no_css(".data-grid.is-scrolled-end")
    end

    it "keeps a table too wide to wrap inside its own frame, not off the page" do
      visit plan_page_path(wide_plan)

      # This is the reported bug: the table used to widen the document.
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(frame_overflows?).to be(true)
      # ...and it says so, rather than hiding the rest silently.
      expect(page).to have_css(".data-grid.is-scrolled-end")
    end

    # The frame is a new scroll container between the mark and the viewport.
    # A `scroll` event from it doesn't bubble, so a popover positioned once
    # against the mark's viewport coordinates would sit still while the mark
    # slid out from under it.
    it "keeps an open thread popover on its mark when the frame scrolls" do
      thread = wide_plan.comment_threads.create!(
        plan_version: wide_plan.current_plan_version,
        anchor_text: "value-2-unbreakable", anchor_occurrence: 1,
        created_by_user: author, status: "open"
      )
      thread.comments.create!(author_type: "human", author_id: author.id,
                              body_markdown: "Where does this value come from?")

      visit plan_page_path(wide_plan)
      find(".data-grid mark.anchor-highlight").click
      expect(page).to have_css("#comment_thread_#{thread.id}_popover", visible: true)

      travel = page.evaluate_script(<<~JS)
        (() => {
          const mark = document.querySelector(".data-grid mark.anchor-highlight")
          const popover = document.querySelector("#comment_thread_#{thread.id}_popover")
          const left = el => el.getBoundingClientRect().left
          const before = { mark: left(mark), popover: left(popover) }
          const frame = document.querySelector(".data-grid__frame")
          frame.scrollLeft += 200
          return new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => {
            resolve({
              mark: Math.round(before.mark - left(mark)),
              popover: Math.round(before.popover - left(popover))
            })
          })))
        })()
      JS

      expect(travel["mark"]).to be > 0
      expect(travel["popover"]).to be_within(2).of(travel["mark"])
    end

    it "pins the header row inside the frame" do
      visit plan_page_path(plan)

      expect(page).to have_css(".data-grid thead th")
      expect(computed(".data-grid thead th", "position")).to eq("sticky")
    end

    it "offers to expand a table big enough to be worth it" do
      visit plan_page_path(plan)

      expect(page).to have_css(".data-grid.is-expandable")
      expect(page).to have_css(".data-grid__expand", visible: :all)
    end

    it "still offers exactly one affordance after a cached back navigation" do
      visit plan_page_path(plan)
      expect(page).to have_css(".data-grid__expand", visible: :all)

      # A Turbo visit, not a fresh load: that's what fills the snapshot cache
      # the back navigation then restores.
      library_path = browse_library_path(handle: author.library.handle)
      page.execute_script("Turbo.visit('#{library_path}')")
      expect(page).to have_current_path(library_path)
      page.go_back
      expect(page).to have_css(".data-grid__frame table")

      # Turbo caches the DOM as the controller left it; without care the
      # affordance is restored *and* appended again.
      expect(page).to have_css(".data-grid__expand", visible: :all, count: 1)
    end
  end

  describe "expanded" do
    before do
      visit plan_page_path(plan)
      open_spreadsheet
    end

    it "titles itself with the heading the table sits under" do
      expect(page).to have_css(".expander__title", text: "Phases")
      expect(page).to have_css(".data-sheet__dimensions", text: "9 rows × 6 columns")
    end

    it "pins both the header row and the row-label column" do
      expect(computed(".data-sheet__table thead th", "position")).to eq("sticky")
      expect(computed(".data-sheet__table tbody tr td:first-child", "position")).to eq("sticky")
    end

    it "starts the cursor on the first cell and moves it with the arrow keys" do
      expect(page).to have_css(".data-sheet__address", text: "A1")
      expect(page).to have_no_css(".data-sheet__value", visible: true)

      find(".data-sheet__table td.is-cursor").send_keys(:arrow_right, :arrow_down)

      expect(page).to have_css(".data-sheet__address", text: "B2")
      expect(page).to have_css(".data-sheet__column", text: "Owner")
      expect(page).to have_no_css(".data-sheet__value", visible: true)
      expect(page).to have_css(".data-sheet__table tr.is-cursor-row td", text: "Ramp")
    end

    it "does not duplicate a value that already fits in its cell" do
      find(".data-sheet__table td.is-cursor").send_keys(:end)

      expect(page).to have_no_css(".data-sheet__value", visible: true)
      expect(page).to have_css("td.is-cursor", text: "Internal merchants only, behind the flag")
    end

    it "keeps the cursor inside the table at the edges" do
      find(".data-sheet__table td.is-cursor").send_keys(:arrow_up, :arrow_left)

      expect(page).to have_css(".data-sheet__address", text: "A1")
    end

    it "sorts a column on click and returns to the document's order" do
      first_owner = -> { page.evaluate_script('document.querySelector(".data-sheet__table tbody td:nth-child(2)").textContent.trim()') }
      expect(first_owner.call).to eq("sam")

      find('.data-sheet__table [aria-label="Sort by Owner"]').click
      expect(page).to have_css(".data-sheet__table thead th.is-sorted-asc", text: "Owner")
      expect(first_owner.call).to eq("ada")

      find('.data-sheet__table [aria-label="Sort by Owner"]').click
      expect(page).to have_css(".data-sheet__table thead th.is-sorted-desc", text: "Owner")
      expect(first_owner.call).to eq("tom")

      find("button[aria-label='Reset sort order']").click
      expect(page).to have_no_css(".data-sheet__table thead th.is-sorted-asc")
      expect(first_owner.call).to eq("sam")
    end

    it "sorts a column of numbers by value, not by its digits as text" do
      find('.data-sheet__table [aria-label="Sort by Traffic"]').click

      order = page.evaluate_script(
        'Array.from(document.querySelectorAll(".data-sheet__table tbody td:nth-child(4)")).map(c => c.textContent.trim())'
      )
      expect(order).to eq([ "0%", "0%", "2%", "5%", "10%", "25%", "40%", "60%", "100%" ])
    end

    it "gives the keyboard back to the grid after a toolbar click" do
      find("button[aria-label='Wrap cell text']").click
      page.driver.browser.action.send_keys(:arrow_down).perform

      expect(page).to have_css(".data-sheet__address", text: "A2")
    end

    it "stays open when you click inside it" do
      find(".data-sheet__table tbody td", text: "Ramp").click

      expect(page).to have_css(".expander--grid")
      expect(page).to have_css(".data-sheet__address", text: "A2")
    end

    it "closes on Escape, leaving the document's own table untouched" do
      find(".data-sheet__table td.is-cursor").send_keys(:escape)

      expect(page).to have_no_css(".expander--grid")
      expect(page).to have_css(".data-grid__frame table")
    end
  end

  it "leaves a table small enough to read as it is" do
    small = CoPlan::Plan.create!(title: "Small Plan", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: small, revision: 1, actor_type: "human", actor_id: author.id,
      content_markdown: "| A | B |\n|---|---|\n| 1 | 2 |\n"
    )
    small.update!(current_plan_version: version, current_revision: 1)

    visit plan_page_path(small)

    expect(page).to have_css(".data-grid__frame table")
    expect(page).to have_no_css(".data-grid.is-expandable")
  end
end
