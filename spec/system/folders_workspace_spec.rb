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

    it "returns to the folder you came from with Backspace on a plan page" do
      # Turbo navigations never update document.referrer, so this relies on
      # the controller's own in-app visit tracking — a regression here sends
      # Backspace to the workspace root, losing your place.
      visit plans_path
      find(".folder-row", text: "Team EBT").click
      find(".folder-row", text: "Q3").click
      find(".plan-row", text: "Q3 Launch Plan").click
      expect(page).to have_css("h1", text: "Q3 Launch Plan")

      find("body").send_keys(:backspace)
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Q3")
    end

    it "falls back to the plan's folder on Backspace after a cold open" do
      # Direct visit = no in-app history. Backspace should land where the
      # plan lives in the viewer's library, not the workspace root.
      visit plan_path(foldered_plan)
      expect(page).to have_css("h1", text: "Q3 Launch Plan")

      find("body").send_keys(:backspace)
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Q3")
      expect(page).to have_current_path(plans_path(folder: q3.id))
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

    it "clears filters with Escape, then jumps home from a folder" do
      developing_plan.tag_names = [ "security" ]
      visit plans_path(tag: "security")

      expect(page).to have_css(".active-filter__clear")
      find("body").send_keys(:escape)
      expect(page).not_to have_css(".active-filter__clear")

      # No filters left: Escape from inside a folder jumps back to the root.
      find(".folder-row", text: "Team EBT").click
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Team EBT")
      find("body").send_keys(:escape)
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
      developing_plan.tag_names = [ "security" ]
      visit plans_path

      within(".workspace__sidebar") { click_link "#security" }
      expect(page).to have_content("Payments Plan")
      expect(page).not_to have_content("Q3 Launch Plan")
    end

    it "creates a nested folder through the popover, defaulting to the current folder" do
      visit plans_path(folder: team.id)
      click_button "New folder"

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

    it "files a plan via the row bookmark's folder navigator" do
      visit plans_path

      row = find(".plan-row[data-plan-id='#{developing_plan.id}']")
      row.find(".plan-row__save", visible: :all).click

      within("#folder-picker-modal") do
        # The tree is hierarchical: Q3 nests under Team EBT.
        expect(page).to have_css(".folder-picker__tree--nested .folder-picker__name", text: "Q3")
        find(".folder-picker__option", text: "Q3").click
      end

      expect(page).to have_css(".flash--notice", text: "Team EBT/Q3", wait: 5)
      expect(author.library.placements.find_by(plan_id: developing_plan.id).folder).to eq(q3)
    end

    it "saves from the plan page via the bookmark beside the title" do
      visit plan_path(developing_plan)

      # The bookmark mounts into the title row (it's stamped client-side —
      # the broadcast-replaced header can't render viewer state itself).
      find(".page-header__title-row .plan-bookmark").click
      within("#folder-picker-modal") do
        find(".folder-picker__option", text: "Infra").click
      end

      expect(page).to have_css(".flash--notice", text: "Infra", wait: 5)
      expect(author.library.placements.find_by(plan_id: developing_plan.id).folder).to eq(infra)
      # After the reload the bookmark reads as saved.
      expect(page).to have_css(".plan-bookmark--saved")
    end

    it "unsaves a filed plan with a second bookmark click — no dialog, no toast" do
      CoPlan::Plans::Place.call(plan: developing_plan, folder: q3, actor: author)
      visit plans_path(folder: q3.id)

      row = find(".plan-row[data-plan-id='#{developing_plan.id}']")
      row.find(".plan-row__save--saved", visible: :all).click

      # The bookmark just lets go: no navigator, no confirmation, no toast —
      # the page re-renders and the plan is out of the folder.
      expect(page).not_to have_css("#folder-picker-modal:popover-open")
      expect(page).not_to have_css(".plan-row[data-plan-id='#{developing_plan.id}']", wait: 5)
      expect(page).not_to have_css(".flash--notice")
      expect(author.library.placements.where(plan_id: developing_plan.id)).to be_empty
    end

    it "offers save controls on other users' plans too (shelving)" do
      other_plan = create(:plan, :considering, created_by_user: other, title: "Someone Elses Plan")
      visit plans_path(scope: "all")

      row = find(".plan-row[data-plan-id='#{other_plan.id}']")
      expect(row["draggable"]).to eq("true")
      expect(row).to have_css(".plan-row__save", visible: :all)
    end
  end

  describe "spring-loaded folders" do
    let!(:q3sub) { create(:folder, name: "Q3 Sub", parent: q3, created_by_user: author) }

    # Capybara's drag_to is atomic — no way to hover mid-drag — so these
    # drive the controller with synthetic DragEvents sharing one
    # DataTransfer, exactly the objects the real drag hands it.
    def fire_drag_event(element, type)
      page.execute_script(<<~JS, element)
        if (#{(type == "dragstart").to_json}) window.__springDT = new DataTransfer()
        arguments[0].dispatchEvent(new DragEvent(#{type.to_json}, {
          bubbles: true, cancelable: true, dataTransfer: window.__springDT
        }))
      JS
    end

    it "springs a collapsed sidebar branch open after a hover, and shut when the drag moves away" do
      visit plans_path

      row = find(".plan-row[data-plan-id='#{developing_plan.id}']")
      branch_link = find(".folder-tree__link", text: "Team EBT")

      # Q3 is buried in a collapsed <details> branch.
      expect(page).not_to have_css(".folder-tree__link", text: "Q3")

      fire_drag_event(row, "dragstart")
      fire_drag_event(branch_link, "dragover")

      # Two pulses first, then the branch springs open (650ms).
      expect(branch_link[:class]).to include("dnd-spring")
      expect(page).to have_css(".folder-tree__branch[open] .folder-tree__link", text: "Q3", wait: 2)

      # Drag away — the sprung branch snaps shut ("temporarily there").
      fire_drag_event(find(".folder-tree__link", text: "Infra"), "dragover")
      expect(page).not_to have_css(".folder-tree__link", text: "Q3")

      fire_drag_event(row, "dragend")
    end

    it "tunnels the pane into a hovered folder, level by level, and files a dead-space drop right there" do
      visit plans_path

      row = find(".plan-row[data-plan-id='#{developing_plan.id}']")
      fire_drag_event(row, "dragstart")
      fire_drag_event(find(".folder-row", text: "Team EBT"), "dragover")

      # Two pulses later the pane IS Team EBT's level view — real crumbs,
      # real rows — while the drag is still in flight.
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Team EBT", wait: 4)
      expect(page).to have_css(".folder-row", text: "Q3")

      # Keep diving: hover Q3 to tunnel one level deeper.
      fire_drag_event(find(".folder-row", text: "Q3"), "dragover")
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Q3", wait: 4)
      expect(page).to have_css(".folder-row", text: "Q3 Sub")

      # Dead space in the pane files into the folder you're looking at.
      fire_drag_event(find(".workspace__main"), "drop")
      fire_drag_event(row, "dragend")

      expect(page).to have_css(".flash--notice", wait: 5)
      expect(author.library.placements.find_by(plan_id: developing_plan.id).folder).to eq(q3)
      # The drop leaves you where you dropped — inside Q3, for real.
      expect(page).to have_current_path(plans_path(folder: q3.id), wait: 5)
    end

    it "restores the original pane when a tunneled drag ends without a drop" do
      visit plans_path

      row = find(".plan-row[data-plan-id='#{developing_plan.id}']")
      fire_drag_event(row, "dragstart")
      fire_drag_event(find(".folder-row", text: "Team EBT"), "dragover")
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Team EBT", wait: 4)

      # Abandon the drag: everything snaps back — root crumb, root rows,
      # and the dragged row itself.
      fire_drag_event(row, "dragend")
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "My Plans")
      expect(page).to have_css(".folder-row", text: "Team EBT")
      expect(page).to have_css(".plan-row[data-plan-id='#{developing_plan.id}']")
      expect(author.library.placements.where(plan_id: developing_plan.id)).to be_empty
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
