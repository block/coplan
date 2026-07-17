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

    it "creates a folder from the sidebar" do
      visit plans_path
      find(".sidebar__new-folder-toggle").click
      fill_in "Folder name", with: "Fresh Folder"
      click_button "Create"

      expect(page).to have_content("Folder “Fresh Folder” created.")
      expect(page).to have_content("No plans")
      within(".workspace__sidebar") { expect(page).to have_content("Fresh Folder") }
    end
  end

  describe "collapsible visibility groups" do
    it "collapses drafts by default and persists toggles across reloads" do
      visit plans_path

      # Draft group is collapsed by default: header visible, rows hidden.
      expect(page).to have_css('[data-group-key="draft"]')
      expect(page).not_to have_content("Secret Idea")

      # Expand it.
      find('[data-group-key="draft"] .plan-group__toggle').click
      expect(page).to have_content("Secret Idea")

      # Collapse published.
      find('[data-group-key="published"] .plan-group__toggle').click
      expect(page).not_to have_content("Payments Plan")

      # State persists across a reload (localStorage).
      visit plans_path
      expect(page).to have_content("Secret Idea")
      expect(page).not_to have_content("Payments Plan")
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

      # The row now shows its folder breadcrumb after the refresh.
      expect(page).to have_css(".plan-row[data-plan-id='#{developing_plan.id}'] .plan-row__folder", text: "Infra")
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
