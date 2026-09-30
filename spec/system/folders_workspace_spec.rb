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
    expect(page).to have_button("Menu")
  end

  before { sign_in(author) }

  describe "Drive-style navigation" do
    it "walks down through folders and back up via breadcrumbs" do
      visit library_page_path(author)

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
      visit library_page_path(author)
      find(".folder-row", text: "Team EBT").click
      find(".folder-row", text: "Q3").click
      find(".plan-row", text: "Q3 Launch Plan").click
      expect(page).to have_css("h1", text: "Q3 Launch Plan")

      find("body").send_keys(:backspace)
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Q3")
    end

    it "falls back to the plan's folder on Backspace after a cold open" do
      # Direct visit = no in-app history. Backspace should land on the
      # folder the plan lives in — at its readable address, not the
      # workspace root and not a folder-id query string.
      visit plan_page_path(foldered_plan)
      expect(page).to have_css("h1", text: "Q3 Launch Plan")

      find("body").send_keys(:backspace)
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Q3")
      expect(page).to have_current_path(browse_path(handle: author.library.handle, slug_path: q3.slug_path))
    end

    it "returns to the containing folder after archiving a filed plan" do
      visit plan_page_path(foldered_plan)
      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { click_button "Archive plan" }

      expect(page).to have_current_path(browse_path(handle: author.library.handle, slug_path: q3.slug_path))
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Q3")
      expect(page).to have_link("View archived", href: browse_path(handle: author.library.handle, slug_path: q3.slug_path, filter: "archived"))
      expect(page).not_to have_css(".plan-row[data-plan-id='#{foldered_plan.id}']")
      expect(foldered_plan.reload.archived?).to be(true)

      within(".archive-confirmation") { click_button "Undo archive" }
      expect(page).to have_current_path(browse_path(handle: author.library.handle, slug_path: q3.slug_path))
      expect(page).to have_css(".plan-row[data-plan-id='#{foldered_plan.id}']")
      expect(foldered_plan.reload.archived?).to be(false)
    end

    it "fetches the archived state when going back to the plan" do
      visit plan_page_path(foldered_plan)
      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { click_button "Archive plan" }
      expect(page).to have_current_path(browse_path(handle: author.library.handle, slug_path: q3.slug_path))

      page.go_back
      expect(page).to have_css(".plan-banner--archived", wait: 10)
      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { expect(page).to have_no_button("Archive plan") }
    end

    it "keeps the folder scroll position when Undo restores its row" do
      visit plan_page_path(foldered_plan)
      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { click_button "Archive plan" }
      expect(page).to have_css("#archive-confirmation")

      page.execute_script(<<~JS)
        document.querySelector('.workspace__main').style.minHeight = '1600px'
        window.scrollTo(0, 200)
      JS
      previous_scroll = page.evaluate_script("window.scrollY")
      expect(previous_scroll).to be > 0
      page.execute_script("document.querySelector('#archive-confirmation form').requestSubmit()")

      expect(page).to have_css(".plan-row[data-plan-id='#{foldered_plan.id}']")
      expect(page).to have_no_css("#archive-confirmation")
      expect(page.evaluate_script("window.scrollY")).to be_within(2).of(previous_scroll)
    end

    it "goes up to the plan's containing folder from the masthead and sticky nav" do
      foldered_plan.current_plan_version.update!(
        content_markdown: (1..30).map { |n| "## Section #{n}\n\nEnough content to scroll past the masthead." }.join("\n\n")
      )
      # The masthead links straight at the canonical browsable path, so
      # clicking it lands there with no redirect hop.
      location_path = browse_path(handle: author.library.handle, slug_path: q3.slug_path)
      workspace_destination = location_path

      visit plan_page_path(foldered_plan)
      masthead_location = find(".plan-location-link--masthead")
      expect(masthead_location[:href]).to end_with(location_path)
      expect(masthead_location["aria-label"]).to eq("Up to containing folder — Team EBT/Q3")
      expect(masthead_location["data-turbo-prefetch"]).to eq("true")
      masthead_location.click
      expect(page).to have_current_path(workspace_destination)

      visit plan_page_path(foldered_plan)
      page.execute_script("window.scrollTo(0, document.body.scrollHeight)")
      expect(page).to have_css(".site-nav__plan-context--visible")
      sticky_location = find(".plan-location-link--nav")
      expect(sticky_location[:href]).to end_with(location_path)
      expect(sticky_location["aria-label"]).to eq("Up to containing folder — Team EBT/Q3")
      expect(sticky_location["data-turbo-prefetch"]).to eq("true")
      sticky_location.click
      expect(page).to have_current_path(workspace_destination)
    end

    it "opens the author's navigable folder when viewing someone else's plan" do
      saved = create(:folder, name: "Saved by me", created_by_user: other)
      CoPlan::Plans::Place.call(plan: foldered_plan, folder: saved, actor: other)
      sign_in(other)
      # The author's canonical path — a plan's location is where its author
      # filed it, not where this viewer shelved it.
      destination = browse_path(handle: author.library.handle, slug_path: q3.slug_path)

      visit plan_page_path(foldered_plan)
      location = find(".plan-location-link--masthead")
      expect(location[:href]).to end_with(destination)
      expect(location["aria-label"]).to eq("Up to containing folder — Team EBT/Q3")
      location.click

      expect(page).to have_current_path(destination)
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Q3")
      expect(page).to have_link("Q3 Launch Plan")
    end

    it "quietly flags private plans in the level view" do
      visit library_page_path(author)
      row = find(".plan-row[data-plan-id='#{brainstorm_plan.id}']")
      expect(row).to have_css(".state-flag", text: "Private")
    end

    it "navigates docs and folders with j/k/Enter and goes up with Backspace" do
      visit library_page_path(author)

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
      visit library_page_path(author, tag: "security")

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
    it "fits type names and explanations inside desktop cards" do
      CoPlan::PlanTypes::InstallDefaults.call
      visit folder_page_path(team)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 940, height: 900, deviceScaleFactor: 1, mobile: false)
      click_button "Add plan or folder"
      within("#workspace-add-menu") { click_button "Plan" }

      layout = page.evaluate_script(<<~JS)
        (() => {
          const modal = document.querySelector('#new-plan-modal');
          const cards = [...modal.querySelectorAll('.new-plan-types__button')];
          const body = modal.querySelector('.add-modal__body');
          return {
            columns: getComputedStyle(modal.querySelector('.new-plan-types')).gridTemplateColumns.split(' ').length,
            nameFits: cards.every(card => {
              const name = card.querySelector('.new-plan-types__name');
              return name.scrollWidth <= name.clientWidth + 1;
            }),
            descriptionFits: cards.every(card => {
              const description = card.querySelector('.new-plan-types__description');
              return description.scrollHeight <= description.clientHeight + 1;
            }),
            bodyScrolls: body.scrollHeight > body.clientHeight
          };
        })()
      JS
      expect(layout).to eq({ "columns" => 3, "nameFits" => true, "descriptionFits" => true, "bodyScrolls" => false })
      page.save_screenshot(Rails.root.join("tmp/plan-type-picker-desktop.png"))

      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 720, height: 900, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("getComputedStyle(document.querySelector('.new-plan-types')).gridTemplateColumns.split(' ').length")).to eq(2)
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page.driver.browser
    end

    it "turns the plan type picker into a readable phone list" do
      CoPlan::PlanTypes::InstallDefaults.call
      visit folder_page_path(team)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 700, deviceScaleFactor: 1, mobile: true)
      click_button "Add plan or folder"
      within("#workspace-add-menu") { click_button "Plan" }

      layout = page.evaluate_script(<<~JS)
        (() => {
          const modal = document.querySelector('#new-plan-modal');
          const body = modal.querySelector('.add-modal__body');
          const cards = [...modal.querySelectorAll('.new-plan-types__button')];
          const bounds = modal.getBoundingClientRect();
          return {
            viewportWidth: innerWidth,
            cardCount: cards.length,
            columns: getComputedStyle(modal.querySelector('.new-plan-types')).gridTemplateColumns.split(' ').length,
            insideViewport: bounds.left >= 0 && bounds.right <= innerWidth && bounds.top >= 0 && bounds.bottom <= innerHeight,
            cardsFit: cards.every(card => card.scrollWidth <= card.clientWidth + 1),
            cardLayout: cards.every(card => {
              const icon = card.querySelector('.new-plan-types__icon').getBoundingClientRect();
              const name = card.querySelector('.new-plan-types__name').getBoundingClientRect();
              const description = card.querySelector('.new-plan-types__description').getBoundingClientRect();
              return name.left > icon.right && description.top >= name.bottom &&
                Math.abs(description.left - name.left) < 1;
            }),
            bodyScrolls: body.scrollHeight > body.clientHeight,
            cardHeight: cards[0].getBoundingClientRect().height,
            titleSize: parseFloat(getComputedStyle(cards[0].querySelector('strong')).fontSize),
            descriptionSize: parseFloat(getComputedStyle(cards[0].querySelector('small')).fontSize)
          };
        })()
      JS
      expect(layout.slice("viewportWidth", "cardCount", "columns", "insideViewport", "cardsFit", "cardLayout", "bodyScrolls")).to eq(
        { "viewportWidth" => 390, "cardCount" => 12, "columns" => 1, "insideViewport" => true, "cardsFit" => true, "cardLayout" => true, "bodyScrolls" => true }
      )
      expect(layout["cardHeight"]).to be >= 74
      expect(layout["titleSize"]).to be >= 15
      expect(layout["descriptionSize"]).to be >= 12
      page.save_screenshot(Rails.root.join("tmp/plan-type-picker-mobile.png"))
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page.driver.browser
    end

    it "opens an unsaved typed draft and creates it when writing begins" do
      type = create(:plan_type, name: "Design Doc", template_content: "## Problem\n")
      visit folder_page_path(team)
      page.execute_script("sessionStorage.setItem('coplan-editor-mode-#{author.id}', 'markdown')")
      click_button "Add plan or folder"
      within("#workspace-add-menu") { click_button "Plan" }
      expect(page.evaluate_script("document.querySelector('#workspace-add-menu').matches(':popover-open')")).to eq(false)
      within("#new-plan-modal") { click_link "Design Doc" }

      title = find("#plan-header .inline-editor__title[contenteditable='plaintext-only']", wait: 20)
      expect(title.text).to be_empty
      expect(page).to have_css(".inline-editor .ProseMirror", text: "Problem")
      expect(page).to have_css('.document-editor__inline-mode button[data-mode="rich"][aria-pressed="true"]')
      expect(CoPlan::Plan.where(plan_type: type)).to be_empty

      title.send_keys("My design")
      expect(CoPlan::Plan.where(plan_type: type)).to be_empty
      page.execute_script("window.draftEditorForm = document.querySelector('.inline-editor form.document-editor')")
      find(".inline-editor .ProseMirror").click
      page.driver.browser.action.send_keys("Details to write.").perform
      expect(page).to have_css("[data-coplan--inline-editor-target='draftState']", text: "Private · v1", wait: 20)
      expect(page.evaluate_script("window.draftEditorForm === document.querySelector('.inline-editor form.document-editor')")).to eq(true)
      expect(page.evaluate_script("document.querySelector('.inline-editor .ProseMirror').contains(document.activeElement)")).to eq(true)
      draft = CoPlan::Plan.find_by!(title: "My design")
      expect(draft.plan_type).to eq(type)
      expect(draft.placement.folder).to eq(team)
      expect(draft.slug).to eq("my-design")
      expect(page).to have_current_path(plan_page_path(draft), ignore_query: true)
      click_link "Done"
      expect(page).to have_current_path(plan_page_path(draft), wait: 15)
      expect(page).to have_css("#plan-content-body", text: "Details to write.")
    end

    it "opens a blank plan type without creating it" do
      create(:plan_type, name: "Scratchpad", template_content: nil)
      visit folder_page_path(team)
      click_button "Add plan or folder"
      within("#workspace-add-menu") { click_button "Plan" }
      within("#new-plan-modal") { click_link "Scratchpad" }

      expect(page).to have_css("#plan-header .inline-editor__title[contenteditable='plaintext-only']", wait: 20)
      expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']")
      expect(CoPlan::Plan.find_by(title: "Untitled plan")).to be_nil
    end

    it "returns to the folder without creating an untouched draft" do
      type = create(:plan_type, name: "Scratchpad", template_content: nil)
      visit folder_page_path(team)
      click_button "Add plan or folder"
      within("#workspace-add-menu") { click_button "Plan" }
      within("#new-plan-modal") { click_link "Scratchpad" }
      expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)

      find("#plan-header .inline-editor__title").send_keys("Just a title")
      click_link "Done"

      expect(page).to have_current_path(folder_page_path(team))
      expect(CoPlan::Plan.where(plan_type: type)).to be_empty
    end

    it "keeps Done usable if the draft editor has not loaded" do
      type = create(:plan_type, name: "Scratchpad", template_content: nil)
      visit new_plan_path(plan_type_id: type.id, folder_id: team.id)
      expect(page).to have_link("Done")
      page.execute_script(<<~JS)
        const element = document.querySelector('[data-controller="coplan--inline-editor"]')
        window.Stimulus.getControllerForElementAndIdentifier(element, "coplan--inline-editor").controller = null
      JS

      click_link "Done"
      expect(page).to have_current_path(folder_page_path(team))
      expect(CoPlan::Plan.where(plan_type: type)).to be_empty
    end

    it "opens a presentation template in the new draft editor" do
      create(:plan_type, name: "Presentation", template_content: "# Opening slide\n")
      visit folder_page_path(team)
      click_button "Add plan or folder"
      within("#workspace-add-menu") { click_button "Plan" }
      within("#new-plan-modal") { click_link "Presentation" }

      expect(page).to have_css("#plan-header .inline-editor__title[contenteditable='plaintext-only']", wait: 20)
      expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']")
    end

    it "jumps into a folder from the sidebar tree" do
      visit library_page_path(author)

      within(".workspace__sidebar") { click_link "Team EBT" }
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Team EBT")
      expect(page).to have_css(".folder-row", text: "Q3")
      expect(page).not_to have_css(".plan-row[data-plan-id='#{developing_plan.id}']")
    end

    %w[light dark].each do |theme|
      it "creates and navigates five compact folder levels in #{theme} mode, rejecting a sixth" do
        author.update!(theme_preference: theme)
        parent = CoPlan::Folder.find_or_create_by_path!("Features/Feature/Android", library: author.library)
        visit folder_page_path(parent)
        expect(page).to have_css("html[data-theme='#{theme}']")
        sidebar_width = find(".workspace__sidebar").native.rect.width

        %w[Rollout Retro].each do |name|
          click_button "Add plan or folder"
          within("#workspace-add-menu") { click_button "Folder" }
          within("#new-folder-modal") do
            expect(page).to have_select("Inside", selected: parent.path)
            fill_in "Name", with: name
            click_button "Create folder"
          end
          expect(page).to have_css(".workspace-crumbs__crumb--current", text: name)
          parent = author.library.folders.find_by!(name: name)
        end
        expect(parent.depth).to eq(5)

        within(".workspace__sidebar") do
          links = (parent.ancestors + [ parent ]).map do |folder|
            find(".folder-tree__link[data-folder-id='#{folder.id}']")
          end
          # Four extra levels use two rem; disclosure targets remain separate.
          expect(links.last.native.rect.x - links.first.native.rect.x).to eq(32)
          click_link "Android"
        end
        expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Android")
        find(".folder-row", text: "Rollout").click
        find(".folder-row", text: "Retro").click
        expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Retro")
        expect(find(".workspace__sidebar").native.rect.width).to eq(sidebar_width)

        click_button "Add plan or folder"
        within("#workspace-add-menu") { click_button "Folder" }
        within("#new-folder-modal") do
          fill_in "Name", with: "Too deep"
          click_button "Create folder"
        end
        expect(page).to have_css(".flash--alert", text: "maximum folder depth of 5")
        expect(author.library.folders.where(name: "Too deep")).not_to exist
      end
    end

    it "filters by tag from the sidebar" do
      developing_plan.tag_names = [ "security" ]
      visit library_page_path(author)

      within(".workspace__sidebar") do
        find("summary", text: "Filters").click
        click_link "#security"
      end
      expect(page).to have_content("Payments Plan")
      expect(page).not_to have_content("Q3 Launch Plan")
    end

    it "creates a nested folder through the popover, defaulting to the current folder" do
      visit folder_page_path(team)
      click_button "Add plan or folder"
      within("#workspace-add-menu") { click_button "Folder" }

      within("#new-folder-modal") do
        # Regression: scope: :folder used to bind @folder and prefill the
        # current folder's own name.
        expect(find("#new_folder_name").value).to be_blank
        fill_in "Name", with: "Fresh Folder"
        # Parent preselected to the folder being viewed.
        expect(page).to have_select("Inside", selected: "Team EBT")
        click_button "Create folder"
      end

      # Redirected into the new (empty) folder, nested under Team EBT.
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Fresh Folder")
      expect(page).to have_css(".workspace-crumbs__crumb", text: "Team EBT")
      expect(page).to have_content("Nothing in")
    end
  end

  describe "moving plans to folders" do
    it "moves a plan by dragging its row onto a sidebar folder" do
      visit library_page_path(author)

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
      visit library_page_path(author)

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
      visit library_page_path(author)

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

    it "files their own plan via Move to folder… in the plan menu" do
      deepest = CoPlan::Folder.find_or_create_by_path!("Features/Feature/Android/Rollout/Retro", library: author.library)
      visit plan_page_path(developing_plan)

      # Owners organize, they don't "save" — no Save button on your own plan.
      expect(page).not_to have_button("Save")

      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { click_button "Move to folder…" }
      within("#folder-picker-modal") do
        expect(page).to have_css("#folder-picker-title", text: "Move to folder")
        # The tree is hierarchical: Q3 nests under Team EBT.
        expect(page).to have_css(".folder-picker__tree--nested .folder-picker__name", text: "Q3")
        find(".folder-picker__option", text: "Retro").click
      end

      expect(page).to have_css(".flash--notice", text: "Retro", wait: 5)
      expect(author.library.placements.find_by(plan_id: developing_plan.id).folder).to eq(deepest)
    end

    it "unfiles their own plan with the picker's explicit Remove from folder" do
      CoPlan::Plans::Place.call(plan: developing_plan, folder: q3, actor: author)
      visit plan_page_path(developing_plan)

      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { click_button "Move to folder…" }
      within("#folder-picker-modal") do
        # The navigator reads as state: the current folder is marked.
        expect(page).to have_css(".folder-picker__option--current", text: "Q3")
        click_button "Remove from folder"
      end

      expect(page).to have_css(".flash--notice", wait: 5)
      expect(author.library.placements.where(plan_id: developing_plan.id)).to be_empty
    end

    # Reading someone else's plan offers no filing control at all: it lives
    # in their library, and a plan has only the one home.
    it "offers no way to file someone else's plan into your library" do
      other_plan = create(:plan, :considering, created_by_user: other, title: "Someone Elses Plan")

      visit plan_page_path(other_plan)
      expect(page).to have_css("h1", text: "Someone Elses Plan")
      within("#plan-toolbar") do
        expect(page).not_to have_button("Save")
        expect(page).not_to have_button("Saved")
      end

      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { expect(page).not_to have_button("Move to folder…") }
      expect(CoPlan::PlanPlacement.where(plan_id: other_plan.id)).to be_empty
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
      visit library_page_path(author)

      row = find(".plan-row[data-plan-id='#{developing_plan.id}']")
      branch_link = find(".folder-tree__link", text: "Team EBT")
      sidebar_width = find(".workspace__sidebar").native.rect.width

      # Q3 is buried in a collapsed <details> branch.
      expect(page).not_to have_css(".folder-tree__link", text: "Q3")

      fire_drag_event(row, "dragstart")
      fire_drag_event(branch_link, "dragover")

      # Two pulses first, then the branch springs open (650ms).
      expect(branch_link[:class]).to include("dnd-spring")
      expect(page).to have_css(".folder-tree__branch[open] .folder-tree__link", text: "Q3", wait: 2)
      expect(find(".workspace__sidebar").native.rect.width).to eq(sidebar_width)

      # Drag away — the sprung branch snaps shut ("temporarily there").
      fire_drag_event(find(".folder-tree__link", text: "Infra"), "dragover")
      expect(page).not_to have_css(".folder-tree__link", text: "Q3")

      fire_drag_event(row, "dragend")
    end

    it "tunnels the pane into a hovered folder, level by level, and files a dead-space drop right there" do
      visit library_page_path(author)

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
      expect(page).to have_current_path(browse_path(handle: author.library.handle, slug_path: q3.slug_path), wait: 5)
    end

    it "restores the original pane when a tunneled drag ends without a drop" do
      visit library_page_path(author)

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
      deepest = CoPlan::Folder.find_or_create_by_path!("Features/Feature/Android/Rollout/Retro", library: author.library)
      visit folder_page_path(deepest)

      expect(page).to have_css(".workspace__sidebar-toggle", visible: :visible)
      expect(page).to have_css(".workspace__sidebar-sections", visible: :hidden)

      find(".workspace__sidebar-toggle").click
      expect(page).to have_css(".workspace__sidebar-sections", visible: :visible)
      expect(find(".workspace__sidebar-toggle")["aria-expanded"]).to eq("true")
      within(".workspace__sidebar") { click_link "Retro" }
      expect(page).to have_css(".workspace-crumbs__crumb--current", text: "Retro")
    ensure
      page.driver.browser.manage.window.resize_to(1400, 900)
    end
  end
end
