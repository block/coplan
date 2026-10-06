require "rails_helper"

RSpec.describe "Plan discussion and approval", type: :system do
  let(:author) { create(:coplan_user, email: "approval-author@example.com", username: "approval-author", name: "Plan Author") }
  let(:reviewer) { create(:coplan_user, email: "approval-reviewer@example.com", username: "approval-reviewer", name: "Plan Reviewer") }
  let(:plan) { create(:plan, :published, created_by_user: author, title: "Review tray playground") }
  let!(:task) { create(:review_request, plan: plan, reviewer: reviewer) }

  def sign_in_browser(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    if user == author
      expect(page).to have_current_path(library_page_path(user))
    else
      expect(page).to have_link("Go to your library")
    end
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-review-controls")
  end

  before { sign_in_browser(reviewer) }

  it "defaults to discussion, posts ordinary comments and stays pinned without scrolling the reader" do
    expect(page).to have_no_css(".review-tray__discussion", visible: true)
    page.execute_script("window.scrollTo(0, 180)")
    scroll = page.evaluate_script("window.scrollY")
    within(".review-tray") { click_button "Discuss" }
    fill_in "Public review comment", with: "Can we clarify this boundary?", enable_aria_label: true
    within(".review-tray") { click_button "Post comment" }
    expect(page).to have_content("Comment posted to the plan discussion.")
    expect(page).to have_css("#plan-general-comments", text: "Can we clarify this boundary?")
    expect(task.reload).to be_pending
    expect(page.evaluate_script("window.scrollY")).to eq(scroll)
    within(".review-tray") { click_button "Discuss" }
    expect(page).to have_field("Public review comment", with: "", enable_aria_label: true)
  end

  it "uses existing comments for change requests and supports another look without erasing the response" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Please explain the retry contract.", enable_aria_label: true
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_content("Changes requested. Your feedback is in the plan’s comments.")
    expect(page).to have_css("#plan-general-comments", text: "Please explain the retry contract.")
    expect(task.reload.status).to eq("changes_requested")
    sign_in_browser(author)
    click_button "Approvals · 1"
    click_button "Ready for another look"
    expect(page).to have_css(".review-person", text: "Review requested")
    expect(task.reload).to be_pending
    expect(task.review_responses.count).to eq(1)
  end

  it "makes approval deliberate and keeps discussing as the safe default" do
    within(".review-tray") { click_button "Record approval…" }
    expect(page).to have_css(".review-confirmation[open]", text: "AI agents can see this sign-off")
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("Keep discussing")
    click_button "Keep discussing"
    expect(task.review_responses).to be_empty
    expect(page).to have_field("Public review comment", enable_aria_label: true)
    within(".review-tray") { click_button "Record approval…" }
    fill_in "Public note", with: "Satisfied with this version."
    click_button "Approve v1"
    expect(page).to have_content("Your approval of v1 is recorded.")
    expect(task.reload.status).to eq("approved")
    expect(page).to have_css("#plan-general-comments", text: "Satisfied with this version.")
    click_button "Approvals · 1"
    find("summary", text: "Approval history").click
    expect(page).to have_css(".review-history", text: "Plan Reviewer approved v1")
    expect(page).to have_content("Satisfied with this version.")
  end

  it "refuses sign-off when the viewed version changed and keeps the public note" do
    within(".review-tray") { click_button "Record approval…" }
    fill_in "Public note", with: "An unsent approval note"
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "Changed while reviewing")
    plan.update!(current_plan_version: version, current_revision: 2)
    click_button "Approve v1"
    expect(page).to have_content("The plan has changed. Review the latest version")
    expect(page).to have_field("Public note", with: "An unsent approval note")
    expect(task.review_responses).to be_empty
  end

  it "compares later edits while preserving the approval of the earlier version" do
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "A clarified retry contract.")
    plan.update!(current_plan_version: version, current_revision: 2)
    visit plan_page_path(plan)
    within(".review-tray") { click_button "Changes since approval" }
    expect(page).to have_css(".review-comparison[open]", text: "Version 1 → 2")
    expect(page).to have_content("A clarified retry contract.")
    expect(page).to have_content("The earlier approval remains recorded")
    expect(task.reload.status).to eq("approved")
    expect(task.latest_approval.plan_version.revision).to eq(1)
  end

  it "retains drafts on failure and on live review refreshes" do
    within(".review-tray") { click_button "Discuss" }
    fill_in "Public review comment", with: "Keep this unsent comment", enable_aria_label: true
    page.execute_script("document.getElementById('plan-review-controls').dispatchEvent(new CustomEvent('coplan:reviews-changed'))")
    expect(page).to have_field("Public review comment", with: "Keep this unsent comment", enable_aria_label: true)
    page.execute_script <<~JS
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (options?.method === 'POST') {
          window.fetch = originalFetch;
          return Promise.resolve(new Response('Unavailable', { status: 503 }));
        }
        return originalFetch(url, options);
      };
    JS
    within(".review-tray") { click_button "Post comment" }
    expect(page).to have_css("#review-discussion-error", text: "Your draft is still here")
    expect(page).to have_field("Public review comment", with: "Keep this unsent comment", enable_aria_label: true)
    within(".review-tray") { click_button "Post comment" }
    expect(page).to have_content("Comment posted to the plan discussion.")
  end

  it "lets the author find a person and assign required or optional review" do
    other = create(:coplan_user, username: "new-reviewer", name: "Another Reviewer", email: "another-reviewer@example.com")
    task.update!(status: "withdrawn")
    sign_in_browser(author)
    expect(page).to have_no_css(".review-tray", visible: :all)
    click_button "Approvals", exact: true
    fill_in "Request a review", with: "Another Reviewer"
    expect(page).to have_css(".review-search-result", text: "Another Reviewer")
    find(".review-search-result", text: "Another Reviewer").click
    select "Optional", from: "Review type"
    click_button "Request review", exact: true
    expect(page).to have_css(".review-person", text: "Another Reviewer")
    expect(plan.review_requests.find_by!(reviewer: other).requirement).to eq("optional")
    expect(page).to have_css(".review-tray", visible: :all)
  end

  it "uses the existing dictation composer and keeps the bar within narrow screens in both themes" do
    within(".review-tray") { click_button "Discuss" }
    expect(page).to have_css('.review-tray [data-controller="coplan--dictation"]')
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/tray-#{theme}.png"))
    end
    fill_in "Public review comment", with: "A draft for mobile", enable_aria_label: true
    page.current_window.resize_to(360, 760)
    tray = find(".review-tray").rect
    expect(tray.x).to be >= 0
    expect(tray.x + tray.width).to be <= page.evaluate_script("window.innerWidth")
    expect(page).to have_field("Public review comment", with: "A draft for mobile", enable_aria_label: true)
    expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= page.evaluate_script("window.innerWidth")
  ensure
    page.current_window.resize_to(1400, 900)
  end
end
