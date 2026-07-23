require "rails_helper"

RSpec.describe "Plan history page", type: :system do
  let(:user) { create(:coplan_user, email: "histuser@example.com") }

  let(:plan_content) do
    <<~MARKDOWN
      # Hello

      - [ ] First task
      - [ ] Second task
    MARKDOWN
  end

  let(:plan) do
    p = CoPlan::Plan.create!(title: "History Plan", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: plan_content,
      actor_type: "human", actor_id: user.id,
      change_summary: "Initial draft"
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

  describe "navigation" do
    it "reaches history via the toolbar's overflow menu and returns via the back link" do
      visit plan_path(plan)

      expect(page).to have_content("First task")
      expect(page).not_to have_content("Initial draft")

      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { click_link "History" }

      # A full page: version entry, plan title, no document body.
      expect(page).to have_content("Initial draft")
      expect(page).to have_link("v1")
      expect(page).not_to have_content("First task")

      find(".history-back").click
      expect(page).to have_content("First task")
    end

    it "redirects old ?tab=history links to the history page" do
      visit plan_path(plan, tab: "history")

      expect(page).to have_content("Initial draft")
      expect(page).to have_link("v1")
      expect(current_path).to eq(history_plan_path(plan))
    end

    it "goes back to the document with Backspace" do
      visit plan_path(plan)
      find("#plan-toolbar button[aria-label='More actions']").click
      within("#plan-menu") { click_link "History" }
      expect(page).to have_content("Initial draft")

      find("body").send_keys(:backspace)
      expect(page).to have_content("First task")
    end
  end

  describe "live update via Turbo Streams" do
    it "shows a new version created while the history page is open" do
      # Create v2 after opening history — the broadcast prepends it live.
      visit history_plan_path(plan)

      expect(page).to have_css("#history-count", text: "1")
      expect(page).to have_link("v1")

      CoPlan::Plans::ReplaceContent.call(
        plan: plan.reload,
        new_content: plan_content + "\nMore.\n",
        base_revision: plan.current_revision,
        actor_type: "human",
        actor_id: user.id,
        change_summary: "Follow-up edit"
      )

      expect(page).to have_link("v2", wait: 5)
      expect(page).to have_content("Follow-up edit")
    end
  end

  describe "inline diff preview" do
    it "auto-loads the latest version's diff in the detail pane" do
      visit history_plan_path(plan)

      expect(page).to have_css("#version-diff")
      expect(page).to have_link("View full version →")
      expect(current_path).to eq(history_plan_path(plan))
    end
  end
end
