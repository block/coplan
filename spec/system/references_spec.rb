require "rails_helper"

RSpec.describe "Plan references", type: :system do
  let(:user) { create(:coplan_user, email: "refuser@example.com") }
  let(:plan) do
    p = CoPlan::Plan.create!(title: "Test Plan", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: "# Hello\n\nSome content here.",
      actor_type: "human", actor_id: user.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  # References live under the document as a footnote section — same page as
  # the content, no tabs.
  def open_add_reference_modal
    within("#footnote-references .plan-footnote__header") { find(".section-add").click }
  end

  describe "footnote section" do
    it "shows content and references on one page" do
      visit plan_page_path(plan)

      expect(page).to have_content("Some content here")
      # Empty state is one quiet line, scoped to the section (attachments
      # has its own "None yet").
      expect(page).to have_css("#footnote-references .plan-footnote__empty", text: "No references yet")
      expect(page).to have_css("#footnote-references .plan-footnote__title", text: /references/i)
    end

    it "includes auto-extracted links as rich resources when they are not citations" do
      version = CoPlan::PlanVersion.create!(
        plan: plan,
        revision: 2,
        content_markdown: "Read the [CoPlan repository](https://github.com/block/coplan) for implementation details.",
        actor_type: "human",
        actor_id: user.id
      )
      plan.update!(current_plan_version: version, current_revision: 2)

      visit plan_page_path(plan)

      within("#plan-extracted-references") do
        link = find_link("CoPlan repository", href: "https://github.com/block/coplan")
        expect(link["target"]).to eq("_blank")
        expect(link["rel"]).to eq("noopener noreferrer")
        expect(page).to have_css(".references-list__meta", text: /GitHub repository\s+·\s+github\.com ↗/)
      end
      expect(page).to have_css("#references-count", text: "1")
    end
  end

  describe "inline reference previews" do
    let(:referenced_plan) do
      p = CoPlan::Plan.create!(title: "Referenced Plan", created_by_user: user)
      version = CoPlan::PlanVersion.create!(
        plan: p,
        revision: 1,
        content_markdown: <<~MARKDOWN,
          # Referenced Plan

          This claim has evidence.[^launch-data] See [§2.1](#section-2-1) for the rollout.

          ## 2.1 Rollout

          Start with a five-percent cohort and monitor errors for one week.

          [^launch-data]: The production sample covered 30 days. [Open the source](https://docs.google.com/document/d/evidence).
        MARKDOWN
        actor_type: "human",
        actor_id: user.id
      )
      p.update!(current_plan_version: version, current_revision: 1)
      p
    end

    # The reference line, as the reader meets it: one paragraph carrying both
    # a citation and a section link. Commenting on it means dragging across
    # both, so these gestures have to be real — a scripted Range fires no
    # mouseenter and synthesizes no click, which is exactly the machinery
    # under test.
    def line_with_references
      find("#plan-content-body p", match: :first)
    end

    def press_at_start_of(element)
      page.driver.browser.action
          .move_to(element.native, -(element.native.rect.width.to_i / 2) + 2, 0)
          .click_and_hold
    end

    # A held button outlives a failed example and would silence the preview
    # for every later one, reporting one regression as a cascade.
    after { page.driver.browser.action.release_actions }

    it "keeps the preview out of the way while a selection is dragged across the line" do
      visit plan_page_path(referenced_plan)

      line = line_with_references
      section_link = find('a.reference-anchor--section[href="#section-2-1"]')

      # Press on plain text and sweep onto the anchor, holding there. The
      # press cannot start on the link — that begins Chrome's native link
      # drag instead of a selection — and the held move has to land on the
      # anchor, since one pointerMove only fires mouseenter for the element
      # under its destination.
      press_at_start_of(line).move_to(section_link.native).perform

      # Longer than HOVER_OPEN_DELAY, so an unguarded controller has time to
      # open the card. It has to sit between two performs: a `pause` inside
      # the chain blocks the renderer, and the timer would never run.
      sleep 0.5

      # Proves the sweep reached the anchor. Without it the assertions below
      # would pass just as well for a gesture that missed.
      expect(page).to have_css("a.reference-anchor--section:hover", visible: :visible)
      expect(page).to have_no_css(".reference-preview", visible: :visible)
      expect(section_link["aria-expanded"]).to eq("false")

      page.driver.browser.action.release.perform

      # The suppression is specific to the drag — an ordinary hover still
      # previews. Moving off the anchor first is load bearing: the pointer is
      # still inside it, and staying inside fires no second mouseenter.
      find("#section-2-1").hover
      section_link.hover
      expect(page).to have_css(".reference-preview__title", text: "2.1 Rollout", visible: :visible)
    end

    it "keeps the preview out of the way when the press lands on the reference itself" do
      visit plan_page_path(referenced_plan)

      section_link = find('a.reference-anchor--section[href="#section-2-1"]')

      # Crossing the anchor arms the open timer, and the press then focuses
      # it — which re-arms, and turns the card away because a press never
      # matches :focus-visible. `duration: 0` is what makes this the gesture
      # worth testing: Selenium's default 250ms move outlasts
      # HOVER_OPEN_DELAY, so the card would already be open before the press
      # landed and the example would be asking a different question.
      page.driver.browser.action(duration: 0).move_to(section_link.native).click_and_hold.perform
      sleep 0.5

      expect(page).to have_no_css(".reference-preview", visible: :visible)
      expect(section_link["aria-expanded"]).to eq("false")

      page.driver.browser.action.release.perform
    end

    # The press above is turned away by asking :focus-visible, not by
    # refusing focus outright — so the reader who never touches a mouse still
    # gets the preview a hover would have given them.
    it "still previews for a reader who reaches the reference with the keyboard" do
      visit plan_page_path(referenced_plan)

      # Focus is moved directly rather than by tabbing: the citation sits
      # ahead of the section link, and walking through it leaves a card
      # opening and a close timer in flight that race the assertion. Scripted
      # focus matches :focus-visible exactly as Tab does, which is the branch
      # under test.
      page.execute_script(%{document.querySelector('a.reference-anchor--section').focus()})

      expect(page.evaluate_script("document.activeElement.className"))
        .to include("reference-anchor--section")
      expect(page).to have_css(".reference-preview__title", text: "2.1 Rollout", visible: :visible)
    end

    # The tempting fix for the drag case is to have #follow bail whenever a
    # selection is live. It must not: the browser dispatches a sweep's click
    # on the paragraph rather than the anchor and will not start a selection
    # from a press on a link, so a selection here is always older than the
    # click and the click is always deliberate. Swallowing it strands the
    # reader for good, because clicking a link never collapses a selection.
    it "still follows a reference clicked while text is selected" do
      visit plan_page_path(referenced_plan)

      line = line_with_references
      press_at_start_of(line)
        .move_to(line.native, (line.native.rect.width.to_i / 2) - 2, 0)
        .release
        .perform

      expect(page.evaluate_script("document.getSelection().toString()"))
        .to include("This claim has evidence")

      find('a.reference-anchor--section[href="#section-2-1"]').click
      expect(page.evaluate_script("window.location.hash")).to eq("#section-2-1")
    end

    it "previews references on hover and follows their links on click" do
      visit plan_page_path(referenced_plan)

      citation = find("a.reference-anchor--footnote")
      citation.hover
      expect(page).to have_css(".reference-preview", text: "production sample covered 30 days", visible: :visible)
      within(".reference-preview") do
        expect(page).to have_no_text("CITATION")
        expect(page).to have_no_text("Reference 1")
        source_link = find_link("Open the source", href: "https://docs.google.com/document/d/evidence")
        expect(source_link["target"]).to eq("_blank")
        expect(source_link["rel"]).to eq("noopener noreferrer")
        expect(source_link["aria-label"]).to eq("Open source: Open the source in a new tab (Google Doc · docs.google.com)")
        expect(source_link).to have_css(".citation-source__meta", text: "Google Doc · docs.google.com ↗")
      end
      expect(page).to have_css("#references-count", text: "1")
      expect(page).to have_no_css("#plan-content-body section[data-footnotes]")
      within("#plan-citations") do
        source_link = find_link("Open the source", href: "https://docs.google.com/document/d/evidence")
        expect(source_link["target"]).to eq("_blank")
        expect(source_link[:class]).to include("citation-source--block")
        expect(source_link).to have_css(".citation-source__meta", text: "Google Doc · docs.google.com ↗")
      end
      within("#plan-references") do
        expect(page).to have_no_link("Open the source", href: "https://docs.google.com/document/d/evidence")
        expect(page).to have_no_text("No references yet.")
      end

      citation.click
      expect(page.evaluate_script("window.location.hash")).to eq("#fn-launch-data")
      expect(page.evaluate_script(<<~JS)).to be(true)
        document.querySelector("#fn-launch-data").getBoundingClientRect().top >=
          document.querySelector(".site-nav").getBoundingClientRect().bottom
      JS

      visit plan_page_path(referenced_plan)
      section_link = find('a.reference-anchor--section[href="#section-2-1"]')
      section_link.hover
      expect(section_link["aria-expanded"]).to eq("true")
      expect(page).to have_no_css(".reference-preview", text: "INTERNAL REFERENCE", visible: :visible)
      expect(page).to have_css(".reference-preview__title", text: "2.1 Rollout", visible: :visible)
      expect(page).to have_css(".reference-preview__body", text: "five-percent cohort", visible: :visible)
      expect(page).to have_no_css(".reference-preview__body", text: "production sample covered 30 days", visible: :visible)

      section_link.click
      expect(page.evaluate_script("window.location.hash")).to eq("#section-2-1")
      expect(page).to have_no_css(".reference-preview__jump")
    end
  end

  describe "adding references via Turbo Stream" do
    it "closes the add-modal via the X button and via Escape" do
      visit plan_page_path(plan)

      open_add_reference_modal
      expect(page).to have_css(".add-modal:popover-open")
      within(".add-modal:popover-open") { find(".add-modal__close").click }
      expect(page).not_to have_css(".add-modal:popover-open")

      open_add_reference_modal
      expect(page).to have_css(".add-modal:popover-open")
      find("body").send_keys(:escape)
      expect(page).not_to have_css(".add-modal:popover-open")
    end

    it "appends the reference to the DOM without a navigation" do
      visit plan_page_path(plan)

      open_add_reference_modal
      expect(page).to have_css(".add-modal:popover-open")

      within(".add-modal:popover-open") do
        fill_in "reference[url]", with: "https://github.com/org/repo"
        fill_in "reference[title]", with: "My Repo"
        fill_in "reference[key]", with: "my-repo"
        click_button "Add reference"
      end

      # Turbo Stream replaces the list — reference appears without navigation
      expect(page).to have_link("My Repo", href: "https://github.com/org/repo")
      expect(page).not_to have_css("#footnote-references .plan-footnote__empty")
      expect(page).to have_no_text("my-repo")

      # Count spans updated in-place via Turbo Stream (separate stream
      # targets) — the footnote header and the document outline.
      expect(page).to have_css("#references-count", text: "1")
      expect(page).to have_css("#nav-references-count", text: "1")

      # The document is still right there — same page, no tabs.
      expect(page).to have_content("Some content here")
    end

    it "supports sequential adds with form re-expansion" do
      visit plan_page_path(plan)

      open_add_reference_modal
      within(".add-modal:popover-open") do
        fill_in "reference[url]", with: "https://github.com/org/repo"
        fill_in "reference[title]", with: "Repo One"
        click_button "Add reference"
      end
      expect(page).to have_content("Repo One")
      expect(page).to have_css("#references-count", text: "1")

      # The Turbo Stream replace swaps out the whole section — including the
      # lightbox, which closes it; user must be able to reopen and add another
      open_add_reference_modal
      within(".add-modal:popover-open") do
        fill_in "reference[url]", with: "https://github.com/org/other"
        fill_in "reference[title]", with: "Repo Two"
        click_button "Add reference"
      end

      expect(page).to have_content("Repo One")
      expect(page).to have_content("Repo Two")
      expect(page).to have_css("#references-count", text: "2")
    end
  end

  describe "removing references via Turbo Stream" do
    it "removes reference from DOM with confirm dialog" do
      create(:reference, plan: plan, url: "https://example.com", title: "Doomed", source: "explicit")

      visit plan_page_path(plan)
      expect(page).to have_content("Doomed")
      expect(page).to have_css("#references-count", text: "1")

      # The quiet remove control appears when the reference row is active.
      within("#plan-references") { find(".references-list__item").hover }

      # data-turbo-confirm triggers a browser confirm dialog. Scoped because
      # the TOC also has a "✕" control.
      accept_confirm("Remove this reference?") do
        within("#plan-references") { click_button "✕" }
      end

      # Turbo Stream removes the reference and updates count
      expect(page).not_to have_content("Doomed")
      expect(page).to have_css("#references-count", text: "0")
      expect(page).to have_css("#footnote-references .plan-footnote__empty", text: "No references yet")
    end
  end

  describe "section keyboard jumps" do
    it "jumps to the references footnote with ] and back up with [" do
      visit plan_page_path(plan)

      find("body").send_keys("]")
      expect(page).to have_css("#footnote-references", visible: :visible)
      # The references section scrolled into view.
      in_view = page.evaluate_script(
        "document.querySelector('#footnote-references').getBoundingClientRect().top < window.innerHeight"
      )
      expect(in_view).to be(true)
    end
  end
end
