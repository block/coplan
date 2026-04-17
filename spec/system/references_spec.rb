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

  describe "Stimulus tab switching" do
    it "toggles panel visibility and updates URL via replaceState" do
      visit plan_path(plan)

      # Content visible, references hidden (display:none)
      expect(page).to have_content("Some content here")
      expect(page).not_to have_content("No references yet")

      click_link "References"

      # JS toggles the hidden class — no page reload
      expect(page).to have_content("No references yet")
      expect(page).not_to have_content("Some content here")

      # Stimulus controller pushes ?tab=references via replaceState
      uri = URI.parse(current_url)
      expect(Rack::Utils.parse_query(uri.query)).to include("tab" => "references")

      click_link "Content"

      # Tab param removed for default tab
      uri = URI.parse(current_url)
      expect(uri.query.to_s).not_to include("tab=")

      # Content restored
      expect(page).to have_content("Some content here")
      expect(page).not_to have_content("No references yet")
    end
  end

  describe "adding references via Turbo Stream" do
    it "appends reference to the DOM without navigating away from the tab" do
      visit plan_path(plan, tab: "references")

      # Open the <details> form
      find("summary", text: "+ Add Reference").click
      expect(page).to have_css("details[open]")

      fill_in "reference[url]", with: "https://github.com/org/repo"
      fill_in "reference[title]", with: "My Repo"
      fill_in "reference[key]", with: "my-repo"
      click_button "Add"

      # Turbo Stream replaces the list — reference appears without navigation
      expect(page).to have_link("My Repo", href: "https://github.com/org/repo")
      expect(page).not_to have_content("No references yet")

      # Count span updated in-place via Turbo Stream (separate stream target)
      expect(page).to have_css("#references-count", text: "1")

      # Still on references tab — Turbo Stream didn't cause a Turbo visit
      # (content tab remains hidden, references tab content is visible)
      expect(page).not_to have_content("Some content here")
      expect(page).to have_content("My Repo")
    end

    it "supports sequential adds with form re-expansion" do
      visit plan_path(plan, tab: "references")

      find("summary", text: "+ Add Reference").click
      fill_in "reference[url]", with: "https://github.com/org/repo"
      fill_in "reference[title]", with: "Repo One"
      click_button "Add"
      expect(page).to have_content("Repo One")
      expect(page).to have_css("#references-count", text: "1")

      # After Turbo Stream replaces the partial, <details> is collapsed;
      # user must be able to re-expand and add another
      find("summary", text: "+ Add Reference").click
      fill_in "reference[url]", with: "https://github.com/org/other"
      fill_in "reference[title]", with: "Repo Two"
      click_button "Add"

      expect(page).to have_content("Repo One")
      expect(page).to have_content("Repo Two")
      expect(page).to have_css("#references-count", text: "2")
    end
  end

  describe "removing references via Turbo Stream" do
    it "removes reference from DOM with confirm dialog" do
      create(:reference, plan: plan, url: "https://example.com", title: "Doomed", source: "explicit")

      visit plan_path(plan, tab: "references")
      expect(page).to have_content("Doomed")
      expect(page).to have_css("#references-count", text: "1")

      # data-turbo-confirm triggers a browser confirm dialog
      accept_confirm("Remove this reference?") do
        click_button "✕"
      end

      # Turbo Stream removes the reference and updates count
      expect(page).not_to have_content("Doomed")
      expect(page).to have_css("#references-count", text: "0")
      expect(page).to have_content("No references yet")
    end
  end

  describe "tab count updates across tab switches" do
    it "updates the references count badge visible in the tab nav" do
      visit plan_path(plan)

      # Count starts at 0
      expect(page).to have_css("#references-count", text: "0")

      # Switch to references, add one
      click_link "References"
      find("summary", text: "+ Add Reference").click
      fill_in "reference[url]", with: "https://github.com/org/repo"
      fill_in "reference[title]", with: "My Repo"
      click_button "Add"

      # Count updated via Turbo Stream — visible even in the tab nav
      expect(page).to have_css("#references-count", text: "1")

      # Switch back to content — count persists (it's outside the panels)
      click_link "Content"
      expect(page).to have_css("#references-count", text: "1")
    end
  end
end
