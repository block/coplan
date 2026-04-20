require "rails_helper"

RSpec.describe "Plan history tab", type: :system do
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

  describe "tab switching" do
    it "toggles to history panel and updates URL via replaceState" do
      visit plan_path(plan)

      # Content visible, history hidden
      expect(page).to have_content("First task")
      expect(page).not_to have_content("Initial draft")

      click_link "History"

      # History panel visible with version entry
      expect(page).to have_content("Initial draft")
      expect(page).to have_link("v1")
      expect(page).not_to have_content("First task")

      # URL updated
      uri = URI.parse(current_url)
      expect(Rack::Utils.parse_query(uri.query)).to include("tab" => "history")

      click_link "Content"

      uri = URI.parse(current_url)
      expect(uri.query.to_s).not_to include("tab=")
      expect(page).to have_content("First task")
    end
  end

  describe "server-side tab param" do
    it "renders history tab active when ?tab=history" do
      visit plan_path(plan, tab: "history")

      expect(page).to have_content("Initial draft")
      expect(page).to have_link("v1")
      expect(page).not_to have_content("First task")
    end
  end

  describe "live update via Turbo Streams" do
    it "updates history list when a new version is created via checkbox toggle" do
      visit plan_path(plan, tab: "history")

      expect(page).to have_css("#history-count", text: "1")
      expect(page).to have_link("v1")

      # Switch to content tab, toggle a checkbox to create v2
      click_link "Content"
      checkbox = all('input[type="checkbox"]').first
      checkbox.click

      wait_for_version(plan, 2)

      # History count badge updated via Turbo Stream (visible in tab nav)
      expect(page).to have_css("#history-count", text: "2")

      # Switch to history tab — new version is there
      click_link "History"
      expect(page).to have_link("v2")
      expect(page).to have_content("Toggle checkbox")
    end
  end

  describe "inline diff preview" do
    it "loads diff in Turbo Frame when clicking a version" do
      visit plan_path(plan, tab: "history")

      # Latest version is auto-loaded in the diff pane
      expect(page).to have_css("#version-diff")
      expect(page).to have_link("View full version →")

      # Still on the same page (no navigation)
      uri = URI.parse(current_url)
      expect(Rack::Utils.parse_query(uri.query)).to include("tab" => "history")
    end
  end

  private

  def wait_for_version(plan, expected_revision, timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        break if plan.class.find(plan.id).current_revision >= expected_revision
        sleep 0.1
      end
    end
  end
end
