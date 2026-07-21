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
      expect(page).to have_css("#footnote-references .plan-footnote__empty", text: "None yet")
      expect(page).to have_css("#footnote-references .plan-footnote__title", text: /references/i)
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

      # Count span updated in-place via Turbo Stream (separate stream target)
      expect(page).to have_css("#references-count", text: "1")

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

      # data-turbo-confirm triggers a browser confirm dialog. Scoped: the
      # TOC's hide button is also a "✕" now that everything shares a page.
      accept_confirm("Remove this reference?") do
        within("#plan-references") { click_button "✕" }
      end

      # Turbo Stream removes the reference and updates count
      expect(page).not_to have_content("Doomed")
      expect(page).to have_css("#references-count", text: "0")
      expect(page).to have_css("#footnote-references .plan-footnote__empty", text: "None yet")
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
