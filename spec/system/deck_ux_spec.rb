require "rails_helper"

# Browser-level coverage for the deck's pointer and navigation behavior:
# the two ways a presenter marks up a live slide (selecting text, and the
# pen), the Mermaid expand chip staying chip-sized on a slide, and the
# back-matter links jumping in place instead of refetching the page.
RSpec.describe "Deck UX", type: :system do
  let(:user) { create(:coplan_user, email: "presenter@example.com") }
  let(:deck_type) { create(:plan_type, name: "Presentation", behavior: "presentation") }

  let(:deck_content) do
    <<~MARKDOWN
      # Shared workspaces

      Every slide earns its layout from its shape alone.

      ---

      ## What the classifier sees

      - A lone heading becomes a title slide
      - One image or diagram takes the whole stage

      ---

      ## How a slide finds its shape

      ```mermaid
      flowchart LR
        markdown --> Split
        Split --> Classify
      ```
    MARKDOWN
  end

  let(:plan) do
    p = create(:plan, :published, created_by_user: user, plan_type: deck_type, title: "Readout deck")
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 2,
      content_markdown: deck_content, actor_type: "human", actor_id: user.id
    )
    p.update!(current_plan_version: version, current_revision: 2)
    p
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
  end

  # Sweeps a real selection across an element the way a presenter drags a
  # line: mouse down inside it, move, release. Selenium's action chain is
  # what makes this a genuine drag — a scripted Range wouldn't exercise the
  # click the browser synthesizes at the end of one.
  def drag_across(selector)
    element = find(selector, match: :first).native
    width = element.rect.width.to_i
    page.driver.browser.action
        .move_to(element, -(width / 2) + 2, 0)
        .click_and_hold
        .move_to(element, (width / 2) - 2, 0)
        .release
        .perform
  end

  def current_slide
    page.evaluate_script(
      %{document.querySelector(".deck-slide--current")?.dataset.slide}
    )
  end

  # Strokes are ephemeral by design, so counting them after the fact is a
  # race with their own fade. Watch the canvas instead and count every
  # stroke that was ever added to it.
  def watch_strokes
    page.execute_script(<<~JS)
      window.__strokes = 0;
      new MutationObserver(records => records.forEach(record => {
        record.addedNodes.forEach(node => {
          if (node.classList?.contains("deck-ink__stroke")) window.__strokes++;
        });
      })).observe(document.querySelector(".deck"), { childList: true, subtree: true });
    JS
  end

  def strokes_drawn
    page.evaluate_script("window.__strokes")
  end

  def start_show
    click_button "Present"
    expect(page).to have_css(".deck--presenting .deck-slide--current", wait: 5)
  end

  def attachments_on_screen?
    page.evaluate_script(<<~JS)
      (() => {
        const box = document.getElementById("footnote-attachments").getBoundingClientRect();
        return box.top < window.innerHeight && box.bottom > 0;
      })()
    JS
  end

  describe "present mode" do
    it "treats a drag as a highlight and a bare click as the next slide" do
      visit plan_path(plan)
      start_show
      expect(current_slide).to eq("1")

      # Advance to a slide with body text to sweep.
      find(".deck-slide--current").click
      expect(current_slide).to eq("2")

      drag_across(".deck-slide--current li")

      # The selection is the point being made — the show must not have moved
      # out from under it, and no comment affordance may cover the slide.
      expect(current_slide).to eq("2")
      expect(page.evaluate_script("document.getSelection().toString()"))
        .to include("A lone heading becomes a title slide")
      expect(page).to have_css(".comment-popover", visible: :hidden)

      # A bare click aimed at the presenter's own highlight still advances,
      # and leaves the mark behind with the slide.
      find(".deck-slide--current li", match: :first).click
      expect(current_slide).to eq("3")
      expect(page.evaluate_script("document.getSelection().toString()")).to eq("")
    end
  end

  describe "the pen" do
    it "paints a drag, holds the slide, and lets the stroke fade on its own" do
      visit plan_path(plan)
      start_show
      find(".deck-slide--current").click
      expect(current_slide).to eq("2")

      send_keys("d")
      expect(page).to have_css(".deck--inking .deck-ink-badge")

      watch_strokes
      drag_across(".deck-slide--current li")

      # The stroke is the point being made: the show holds, and the drag
      # paints instead of selecting.
      expect(strokes_drawn).to eq(1)
      expect(current_slide).to eq("2")
      expect(page.evaluate_script("document.getSelection().toString()")).to eq("")

      # Temporary by design — nothing to erase, nothing saved.
      expect(page).to have_no_css(".deck-ink__stroke", wait: 6)
    end

    it "still advances on a bare click, and leaves no dot behind" do
      visit plan_path(plan)
      start_show
      send_keys("d")
      expect(page).to have_css(".deck--inking")

      watch_strokes
      find(".deck-slide--current").click

      expect(current_slide).to eq("2")
      # A press that never travels is the presenter advancing the show, so
      # the pen must not even create a node — a one-frame dot under every
      # click reads as a rendering bug.
      expect(strokes_drawn).to eq(0)
      # The pen stays out across the slide change.
      expect(page).to have_css(".deck--inking .deck-ink-badge")
    end

    it "puts the pen away on Escape without ending the show" do
      visit plan_path(plan)
      start_show
      send_keys("d")
      expect(page).to have_css(".deck--inking")

      send_keys(:escape)
      expect(page).to have_no_css(".deck--inking")
      expect(page).to have_no_css(".deck-ink-badge")
      expect(page).to have_css(".deck--presenting")

      send_keys(:escape)
      expect(page).to have_no_css(".deck--presenting")
    end
  end

  describe "Mermaid diagrams on a slide" do
    it "keeps the expand control chip-sized instead of scaling it to the canvas" do
      visit plan_path(plan)
      expect(page).to have_css(".deck-slide .mermaid-diagram > svg", wait: 15)

      sizes = page.evaluate_script(<<~JS)
        (() => {
          const diagram = document.querySelector(".deck-slide .mermaid-diagram");
          const icon = diagram.querySelector(".mermaid-diagram__expand svg");
          const box = el => Math.round(el.getBoundingClientRect().width);
          return { diagram: box(diagram.querySelector(":scope > svg")), icon: box(icon) };
        })()
      JS

      # The diagram still takes the stage; the chip's icon stays an icon.
      expect(sizes["diagram"]).to be > 200
      expect(sizes["icon"]).to be <= 24
    end
  end

  describe "back-matter links" do
    it "scrolls to the attachments section without refetching the page" do
      plan.attachments.attach(
        io: StringIO.new("handout"), filename: "handout.txt", content_type: "text/plain"
      )

      visit plan_path(plan)
      expect(page).to have_css(".deck-slide", wait: 5)

      # Turbo counts a same-page fragment link as a full visit, so a bare
      # anchor here refetched and re-rendered the page — and the scroll it
      # then performed raced the deck's async rendering. Nothing may be
      # fetched, and the section must end up on screen.
      page.execute_script(<<~JS)
        window.__visited = false;
        document.addEventListener("turbo:visit", () => { window.__visited = true });
      JS

      find(".content-nav__footnote-link", text: "Attachments").click

      expect(page).to have_current_path(/#footnote-attachments\z/, url: true, wait: 5)
      expect(page.evaluate_script("window.__visited")).to be(false)

      # The jump is a smooth scroll, so poll rather than sample once.
      20.times { break if attachments_on_screen?; sleep 0.15 }
      expect(attachments_on_screen?).to be(true)
    end
  end
end
