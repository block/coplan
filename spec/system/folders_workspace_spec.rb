require "rails_helper"

RSpec.describe "Folders workspace", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }
  let(:other) { create(:coplan_user, email: "other@example.com") }

  let!(:infra) { create(:folder, name: "Infra", created_by_user: author) }
  let!(:team) { create(:folder, name: "Team EBT", created_by_user: author) }
  let!(:q3) { create(:folder, name: "Q3", parent: team, created_by_user: author) }

  let!(:developing_plan) { create(:plan, :developing, created_by_user: author, title: "Payments Plan") }
  let!(:brainstorm_plan) { create(:plan, :brainstorm, created_by_user: author, title: "Secret Idea") }
  let!(:foldered_plan) do
    plan = create(:plan, :considering, created_by_user: author, title: "Q3 Launch Plan")
    CoPlan::Plans::Place.call(plan: plan, folder: q3, actor: author)
    plan
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_content("Sign out")
  end

  before { sign_in(author) }

  describe "sidebar navigation" do
    it "filters plans by folder, including subfolders" do
      visit plans_path

      # Both plans visible before filtering
      expect(page).to have_content("Payments Plan")
      expect(page).to have_content("Q3 Launch Plan")

      # Clicking the parent folder shows subfolder contents too
      within(".workspace__sidebar") { click_link "Team EBT" }
      expect(page).to have_content("Q3 Launch Plan")
      expect(page).not_to have_content("Payments Plan")
      expect(page).to have_content("Folder: Team EBT")

      # Clear the filter
      click_link "Clear all"
      expect(page).to have_content("Payments Plan")
    end

    it "filters by tag from the sidebar" do
      developing_plan.tag_names = ["security"]
      visit plans_path

      within(".workspace__sidebar") { click_link "#security" }
      expect(page).to have_content("Payments Plan")
      expect(page).not_to have_content("Q3 Launch Plan")
    end

    it "creates a folder inline from the sidebar" do
      visit plans_path
      find(".sidebar__new-folder-toggle").click
      # Opening the disclosure focuses the input; Enter submits.
      input = find(".sidebar__new-folder-input")
      input.fill_in with: "Fresh Folder"
      input.send_keys(:enter)

      expect(page).to have_content("Folder “Fresh Folder” created.")
      expect(page).to have_content("No plans")
      within(".workspace__sidebar") { expect(page).to have_content("Fresh Folder") }
    end
  end

  describe "collapsible folder groups" do
    it "shows drafts inline and persists folder-group collapse across reloads" do
      visit plans_path

      # Drafts are no longer a separate group — the row is just quietly
      # flagged wherever it's filed.
      expect(page).not_to have_css('[data-group-key="draft"]')
      expect(page).to have_content("Secret Idea")

      # The filing tree is the grouping: Team EBT (whole subtree) + Unfiled.
      expect(page).to have_css("[data-group-key='folder-#{team.id}']")
      expect(page).to have_css('[data-group-key="unfiled"]')

      # Collapse Team EBT: its rows hide, unfiled rows stay.
      find("[data-group-key='folder-#{team.id}'] .plan-group__toggle").click
      expect(page).not_to have_content("Q3 Launch Plan")
      expect(page).to have_content("Payments Plan")

      # State persists across a reload (localStorage).
      visit plans_path
      expect(page).not_to have_content("Q3 Launch Plan")
      expect(page).to have_content("Payments Plan")
    end
  end

  describe "moving plans to folders" do
    it "moves a plan by dragging its row onto a sidebar folder" do
      visit plans_path

      row = find(".plan-row[data-plan-id='#{developing_plan.id}']")
      target = find(".folder-tree__link", text: "Infra")

      begin
        row.drag_to(target, html5: true)
      rescue Capybara::NotSupportedByDriverError, ArgumentError
        skip "driver does not support HTML5 drag and drop"
      end

      expect(page).to have_css(".flash--notice", text: "Infra", wait: 5)
      expect(author.library.placements.find_by(plan_id: developing_plan.id).folder).to eq(infra)

      # After the refresh the row files under the Infra group (the exact
      # same-folder breadcrumb chip is suppressed inside its own group).
      expect(page).to have_css("[data-group-key='folder-#{infra.id}'] .plan-row[data-plan-id='#{developing_plan.id}']")
    end

    it "nests one folder under another by dragging its tree node" do
      visit plans_path

      source = find(".folder-tree__link", text: "Infra")
      target = find(".folder-tree__link", text: "Team EBT")

      begin
        source.drag_to(target, html5: true)
      rescue Capybara::NotSupportedByDriverError, ArgumentError
        skip "driver does not support HTML5 drag and drop"
      end

      expect(page).to have_css(".flash--notice", text: "Moved “Infra” to Team EBT", wait: 5)
      expect(infra.reload.parent).to eq(team)
    end

    it "moves a plan via the row menu fallback" do
      visit plans_path

      within(".plan-row[data-plan-id='#{developing_plan.id}']") do
        find(".plan-row__menu-toggle").click
        select "Team EBT/Q3", from: "folder_id"
        click_button "Move"
      end

      expect(page).to have_css(".flash--notice", text: "Team EBT/Q3")
      expect(author.library.placements.find_by(plan_id: developing_plan.id).folder).to eq(q3)
    end

    it "offers move controls on other users' plans too (shelving)" do
      other_plan = create(:plan, :considering, created_by_user: other, title: "Someone Elses Plan")
      visit plans_path(scope: "all")

      row = find(".plan-row[data-plan-id='#{other_plan.id}']")
      expect(row["draggable"]).to eq("true")
      expect(row).to have_css(".plan-row__menu", visible: :all)
    end
  end
end
