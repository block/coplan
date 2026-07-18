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

  describe "Drive-style navigation" do
    it "walks down through folders and back up via breadcrumbs" do
      visit plans_path

      # Root level: loose docs and folder rows; filed docs are a click away.
      expect(page).to have_css(".plan-row[data-plan-id='#{developing_plan.id}']")
      expect(page).to have_css(".folder-row", text: "Team EBT")
      expect(page).not_to have_css(".plan-row[data-plan-id='#{foldered_plan.id}']")

      find(".folder-row", text: "Team EBT").click
      expect(page).to have_css(".folder-row", text: "Q3")
      expect(page).not_to have_css(".plan-row[data-plan-id='#{developing_plan.id}']")

      find(".folder-row", text: "Q3").click
      expect(page).to have_content("Q3 Launch Plan")
      # Breadcrumb trail: My Plans › Team EBT › Q3
      within(".workspace-crumbs") do
        expect(page).to have_link("Team EBT")
        click_link "My Plans"
      end
      expect(page).to have_css(".plan-row[data-plan-id='#{developing_plan.id}']")
    end

    it "quietly flags private plans in the level view" do
      visit plans_path
      row = find(".plan-row[data-plan-id='#{brainstorm_plan.id}']")
      expect(row).to have_css(".state-flag", text: "Private")
    end

    it "navigates docs and folders with j/k/Enter and goes up with Backspace" do
      visit plans_path

      find("body").send_keys("j")
      expect(page).to have_css(".workspace-key-selected", count: 1)

      # First item is the first folder row (folders list before docs).
      selected = find(".workspace-key-selected")
      expect(selected.text).to include("Infra")

      find("body").send_keys(:enter)
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Infra")

      find("body").send_keys(:backspace)
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "My Plans")
    end
  end

  describe "sidebar navigation" do
    it "jumps into a folder from the sidebar tree" do
      visit plans_path

      within(".workspace__sidebar") { click_link "Team EBT" }
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Team EBT")
      expect(page).to have_css(".folder-row", text: "Q3")
      expect(page).not_to have_css(".plan-row[data-plan-id='#{developing_plan.id}']")
    end

    it "filters by tag from the sidebar" do
      developing_plan.tag_names = ["security"]
      visit plans_path

      within(".workspace__sidebar") { click_link "#security" }
      expect(page).to have_content("Payments Plan")
      expect(page).not_to have_content("Q3 Launch Plan")
    end

    it "creates a nested folder through the popover, defaulting to the current folder" do
      visit plans_path(folder: team.id)
      within(".workspace__sidebar") { find(".sidebar__new-folder-toggle").click }

      within("#new-folder-modal") do
        # Regression: scope: :folder used to bind @folder and prefill the
        # current folder's own name.
        expect(find("#new_folder_name").value).to be_blank
        fill_in "Name", with: "Fresh Folder"
        # Parent preselected to the folder being viewed.
        expect(page).to have_select("Inside", selected: "Team EBT")
        click_button "Create folder"
      end

      expect(page).to have_content("Folder “Fresh Folder” created.")
      # Redirected into the new (empty) folder, nested under Team EBT.
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Fresh Folder")
      expect(page).to have_css(".workspace-crumbs__crumb", text: "Team EBT")
      expect(page).to have_content("Nothing in")
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

      # After the refresh the doc lives inside Infra, not at the root.
      expect(page).not_to have_css(".plan-row[data-plan-id='#{developing_plan.id}']")
      find(".folder-row", text: "Infra").click
      expect(page).to have_css(".plan-row[data-plan-id='#{developing_plan.id}']")
    end

    it "moves a plan by dragging it onto a folder row in the main pane" do
      visit plans_path

      row = find(".plan-row[data-plan-id='#{developing_plan.id}']")
      target = find(".folder-row", text: "Team EBT")

      begin
        row.drag_to(target, html5: true)
      rescue Capybara::NotSupportedByDriverError, ArgumentError
        skip "driver does not support HTML5 drag and drop"
      end

      expect(page).to have_css(".flash--notice", text: "Team EBT", wait: 5)
      expect(author.library.placements.find_by(plan_id: developing_plan.id).folder).to eq(team)
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

  describe "mobile sidebar" do
    it "collapses the sidebar behind a toggle at phone widths" do
      page.driver.browser.manage.window.resize_to(390, 844)
      visit plans_path

      expect(page).to have_css(".workspace__sidebar-toggle", visible: :visible)
      expect(page).to have_css(".workspace__sidebar-sections", visible: :hidden)

      find(".workspace__sidebar-toggle").click
      expect(page).to have_css(".workspace__sidebar-sections", visible: :visible)
      expect(find(".workspace__sidebar-toggle")["aria-expanded"]).to eq("true")
    ensure
      page.driver.browser.manage.window.resize_to(1400, 900)
    end
  end
end
