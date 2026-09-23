require "rails_helper"

# Expanding a Mermaid diagram. These specs drive the real pipeline — Mermaid
# loads from the CDN pinned in the importmap and renders in the browser — so
# they need network access, same as CI.
RSpec.describe "Expanding a Mermaid diagram", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }

  # Deliberately wide: Fit must show every node even at a small zoom level.
  let(:wide_diagram) do
    chain = (1..14).map { |n| "S#{n}[Stage number #{n}]" }.each_cons(2).map { |a, b| "    #{a} --> #{b}" }
    "```mermaid\nflowchart LR\n#{chain.join("\n")}\n```"
  end

  let(:plan_content) do
    <<~MARKDOWN
      # Payment Flow

      ## The pipeline

      #{wide_diagram}

      The ledger records every movement.
    MARKDOWN
  end

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Diagram Plan", created_by_user: author)
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

  def wait_for_diagram
    expect(page).to have_css(".mermaid-diagram__canvas svg", wait: 20)
  end

  def zoom_percent
    find(".expander__readout").text.to_i
  end

  def canvas_transform
    page.evaluate_script('document.querySelector(".expander__canvas > svg").style.transform')
  end

  before do
    sign_in(author)
    visit plan_page_path(plan)
    wait_for_diagram
  end

  describe "in the document" do
    it "fits the complete wide diagram inside the document" do
      expect(page).to have_no_css(".mermaid-diagram--scrolling")

      readable = page.evaluate_script(<<~JS)
        (() => {
          const canvas = document.querySelector(".mermaid-diagram__canvas")
          const svg = canvas.querySelector("svg")
          const natural = svg.viewBox.baseVal.width
          return {
            scale: svg.getBoundingClientRect().width / natural,
            scrolls: canvas.scrollWidth - canvas.clientWidth > 1
          }
        })()
      JS

      expect(readable["scale"]).to be > 0
      expect(readable["scale"]).to be < 1
      expect(readable["scrolls"]).to be(false)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    end
  end

  describe "expanded" do
    before do
      find(".mermaid-diagram").hover
      find(".mermaid-diagram__expand").click
      expect(page).to have_css(".expander--diagram .expander__canvas > svg")
    end

    it "titles itself with the heading the diagram sits under" do
      expect(page).to have_css(".expander__title", text: "The pipeline")
    end

    it "opens fitted to the screen and can be zoomed from the toolbar" do
      fitted = zoom_percent
      expect(fitted).to be > 0

      find("button[aria-label='Zoom in']").click
      expect(zoom_percent).to be > fitted

      find("button[aria-label='Actual size']").click
      expect(zoom_percent).to eq(100)

      find("button[aria-label='Fit to screen']").click
      expect(zoom_percent).to eq(fitted)
      expect(page.evaluate_script(<<~JS)).to be(true)
        (() => {
          const view = document.querySelector('.expander__canvas').getBoundingClientRect();
          const svg = document.querySelector('.expander__canvas > svg').getBoundingClientRect();
          return svg.left >= view.left && svg.top >= view.top && svg.right <= view.right + 1 && svg.bottom <= view.bottom + 1;
        })()
      JS
    end

    it "zooms from the keyboard" do
      fitted = zoom_percent

      find(".expander__canvas").send_keys("+")
      expect(zoom_percent).to be > fitted

      find(".expander__canvas").send_keys("0")
      expect(zoom_percent).to eq(fitted)
    end

    it "gives the keyboard back to the canvas after a toolbar click" do
      fitted = zoom_percent
      find("button[aria-label='Zoom in']").click
      expect(zoom_percent).to be > fitted

      # Sent to whatever is focused — which has to be the canvas again, or
      # the shortcuts die the moment anyone touches the toolbar.
      page.driver.browser.action.send_keys("0").perform
      expect(zoom_percent).to eq(fitted)
    end

    it "pans on drag, and a drag does not dismiss the surface" do
      click_button "Actual size"
      before_drag = canvas_transform
      canvas = find(".expander__canvas")

      page.driver.browser.action
          .move_to(canvas.native, 0, 0)
          .click_and_hold
          .move_by(60, 40)
          .release
          .perform

      # The old lightbox closed on any click, which is why it could never
      # be panned.
      expect(page).to have_css(".expander--diagram")
      expect(canvas_transform).not_to eq(before_drag)
    end

    it "allows an interactive click immediately after panning" do
      canvas = find(".expander__canvas")
      page.driver.browser.action.move_to(canvas.native, 0, 0).click_and_hold.move_by(60, 40).release.perform
      # Exercise the shared viewport's interactive-child contract without
      # relying on Mermaid's strict-mode policy for authored hyperlinks.
      page.execute_script(<<~JS)
        const link = document.createElement('a');
        link.href = '#';
        link.textContent = 'Open linked detail';
        link.style.cssText = 'position:absolute;top:20px;left:20px';
        link.addEventListener('click', event => { event.preventDefault(); link.textContent = 'Opened linked detail'; });
        document.querySelector('.expander__canvas').append(link);
      JS
      click_link "Open linked detail"
      expect(page).to have_link("Opened linked detail")
      expect(page).to have_css(".expander--diagram")
    end

    it "closes on Escape" do
      find(".expander__canvas").send_keys(:escape)

      expect(page).to have_no_css(".expander--diagram")
      expect(page).to have_css(".mermaid-diagram__canvas svg")
    end
  end

  it "browses on a single click and expands on a double-click in the diagram background" do
    find(".mermaid-diagram__canvas").click(x: 4, y: 4)
    expect(page).to have_no_css(".expander--diagram")
    find(".mermaid-diagram__canvas").double_click(x: 4, y: 4)

    expect(page).to have_css(".expander--diagram .expander__canvas > svg")
  end
end
