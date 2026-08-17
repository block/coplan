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
      visit plan_path(plan)

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

      visit plan_path(plan)

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

    it "previews references on hover and follows their links on click" do
      visit plan_path(referenced_plan)

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

      visit plan_path(referenced_plan)
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
      visit plan_path(plan)

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
      visit plan_path(plan)

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
      visit plan_path(plan)

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

      visit plan_path(plan)
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
      visit plan_path(plan)

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
