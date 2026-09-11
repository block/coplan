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
      expect(page).to have_css(".data-sheet__value-label", text: "Phase")

      find(".data-sheet__table td.is-cursor").send_keys(:arrow_right, :arrow_down)

      expect(page).to have_css(".data-sheet__address", text: "B2")
      expect(page).to have_css(".data-sheet__column", text: "Owner")
      expect(page).to have_css(".data-sheet__value-content", text: "kim")
      expect(page).to have_css(".data-sheet__table tr.is-cursor-row td", text: "Ramp")
    end

    it "shows a long value in full even though the cell itself is clipped" do
      find(".data-sheet__table td.is-cursor").send_keys(:end)

      expect(page).to have_css(".data-sheet__value-label", text: "Notes")
      expect(page).to have_css(".data-sheet__value-content",
                               text: "Internal merchants only, behind the flag")
    end

    it "keeps the cursor inside the table at the edges" do
      find(".data-sheet__table td.is-cursor").send_keys(:arrow_up, :arrow_left)

      expect(page).to have_css(".data-sheet__address", text: "A1")
    end

    it "sorts a column on click and returns to the document's order" do
      first_owner = -> { page.evaluate_script('document.querySelector(".data-sheet__table tbody td:nth-child(2)").textContent.trim()') }
      expect(first_owner.call).to eq("sam")

      find(".data-sheet__table thead th", text: "Owner").click
      expect(page).to have_css(".data-sheet__table thead th.is-sorted-asc", text: "Owner")
      expect(first_owner.call).to eq("ada")

      find(".data-sheet__table thead th", text: "Owner").click
      expect(page).to have_css(".data-sheet__table thead th.is-sorted-desc", text: "Owner")
      expect(first_owner.call).to eq("tom")

      find("button[aria-label='Reset sort order']").click
      expect(page).to have_no_css(".data-sheet__table thead th.is-sorted-asc")
      expect(first_owner.call).to eq("sam")
    end

    it "sorts a column of numbers by value, not by its digits as text" do
      find(".data-sheet__table thead th", text: "Traffic").click

      order = page.evaluate_script(
        'Array.from(document.querySelectorAll(".data-sheet__table tbody td:nth-child(4)")).map(c => c.textContent.trim())'
      )
      expect(order).to eq([ "0%", "0%", "2%", "5%", "10%", "25%", "40%", "60%", "100%" ])
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
