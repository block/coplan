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

  it "offers equal review choices and preserves cancelled feedback without moving the reader" do
    within(".review-tray__actions") do
      expect(page).to have_button("Request changes")
      expect(page).to have_button("Approve", exact: true)
      expect(page).to have_no_button("Discuss")
    end
    styles = page.evaluate_script <<~JS
      Array.from(document.querySelectorAll('.review-tray__actions button')).map(button => {
        const style = getComputedStyle(button);
        return [style.backgroundColor, style.color, style.borderColor, style.fontWeight];
      })
    JS
    expect(styles.length).to eq(2)
    expect(styles.first).to eq(styles.last)
    page.execute_script("window.scrollTo(0, 180)")
    scroll = page.evaluate_script("window.scrollY")
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Can we clarify this boundary?", enable_aria_label: true
    within(".review-tray") { click_button "Cancel" }
    expect(task.reload).to be_pending
    expect(task.review_responses).to be_empty
    expect(page.evaluate_script("window.scrollY")).to eq(scroll)
    within(".review-tray") { click_button "Request changes" }
    expect(page).to have_field("Public review comment", with: "Can we clarify this boundary?", enable_aria_label: true)
  end

  it "uses existing comments for change requests and supports another look without erasing the response" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Please explain the retry contract.", enable_aria_label: true
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_content("Changes requested. Your feedback is in the plan’s comments.")
    expect(page).to have_css("#plan-general-comments", text: "Please explain the retry contract.")
    expect(task.reload.status).to eq("changes_requested")
    sign_in_browser(author)
    click_button "More actions"
    click_button "Manage approvals"
    click_button "Actions for Plan Reviewer"
    click_button "Ready for another look"
    expect(page).to have_css(".review-person", text: "Review requested")
    expect(task.reload).to be_pending
    expect(task.review_responses.count).to eq(1)
  end

  it "requires deliberate agreement with the whole version before approval" do
    within(".review-tray") { click_button "Approve" }
    expect(page).to have_css(".review-confirmation[open]", text: "I have read v1 and agree with all of its content.")
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("Cancel")
    click_button "Cancel"
    expect(task.review_responses).to be_empty
    expect(page).to have_no_css(".review-tray__discussion", visible: true)
    within(".review-tray") { click_button "Approve" }
    fill_in "Public note", with: "Satisfied with this version."
    click_button "Approve v1"
    expect(page).to have_content("Your approval of v1 is recorded.")
    expect(task.reload.status).to eq("approved")
    expect(page).to have_css("#plan-general-comments", text: "Satisfied with this version.")
    expect(page).to have_css("#footnote-approvals .review-history", text: /Plan Reviewer approved\s+v1/)
    expect(page).to have_content("Satisfied with this version.")
  end

  it "refuses sign-off when the viewed version changed and keeps the public note" do
    within(".review-tray") { click_button "Approve" }
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
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "Keep this unsent comment", enable_aria_label: true
    task.update!(requirement: "optional")
    page.execute_script("document.getElementById('plan-review-controls').dispatchEvent(new CustomEvent('coplan:reviews-changed'))")
    expect(page).to have_css("[data-review-status]", text: "Optional")
    expect(page).to have_field("Public review comment", with: "Keep this unsent comment", enable_aria_label: true)
    expect(page).to have_css('.review-tray__actions button[aria-expanded="true"]', text: "Request changes")
    page.execute_script <<~JS
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (options?.method === 'POST') {
          window.fetch = originalFetch;
          return Promise.reject(new TypeError('Failed to fetch'));
        }
        return originalFetch(url, options);
      };
    JS
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_css("#review-discussion-error", text: "Couldn't reach CoPlan. Your draft is still here")
    expect(page).to have_field("Public review comment", with: "Keep this unsent comment", enable_aria_label: true)
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_content("Changes requested. Your feedback is in the plan’s comments.")
  end

  it "lets the author find a person and assign required or optional review" do
    other = create(:coplan_user, username: "new-reviewer", name: "Another Reviewer", email: "another-reviewer@example.com")
    task.update!(status: "withdrawn")
    sign_in_browser(author)
    expect(page).to have_no_css(".review-tray", visible: :all)
    click_button "More actions"
    click_button "Manage approvals"
    within(".review-management") { click_button "Add reviewer", exact: true }
    fill_in "Find a reviewer", with: "Another Reviewer"
    expect(page).to have_css(".review-search-result", text: "Another Reviewer")
    find(".review-search-result", text: "Another Reviewer").click
    uncheck "Required"
    within(".review-assignment-form") { click_button "Add reviewer", exact: true }
    expect(page).to have_css(".review-person", text: "Another Reviewer")
    expect(plan.review_requests.find_by!(reviewer: other).requirement).to eq("optional")
    expect(page).to have_no_css(".review-tray", visible: :all)
    sign_in_browser(other)
    expect(page).to have_css(".review-tray", visible: true)
  end

  it "acknowledges saved feedback even if refreshing its comment fails" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "A saved request", enable_aria_label: true
    page.execute_script <<~JS
      const originalFetch = window.fetch;
      const commentsUrl = document.querySelector('[data-coplan--inline-editor-comments-url-value]').getAttribute('data-coplan--inline-editor-comments-url-value');
      window.fetch = (url, options) => {
        if (url === commentsUrl) {
          window.fetch = originalFetch;
          return Promise.reject(new TypeError('Failed to fetch'));
        }
        return originalFetch(url, options);
      };
    JS
    within(".review-tray__discussion") { click_button "Request changes" }
    expect(page).to have_content("Changes requested. Your feedback is in the plan’s comments. Refresh the page to see your comment.")
    expect(task.reload.review_responses.count).to eq(1)
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-general-comments", text: "A saved request")
  end

  it "orders required reviewers first and keeps management actions in dropdowns" do
    other = create(:coplan_user, name: "Another Reviewer")
    optional = create(:review_request, plan: plan, reviewer: other, requirement: "optional", requested_at: 1.day.ago)
    sign_in_browser(author)
    click_button "More actions"
    click_button "Manage approvals"
    within(".review-management") do
      expect(all(".review-group h3").map { |heading| heading.text.gsub(/\s+/, " ") }).to eq([ "Required 1", "Optional 1" ])
      expect(page).to have_no_button("Make required")
      click_button "Actions for Another Reviewer", enable_aria_label: true
      click_button "Make required"
      expect(page).to have_css(".review-group h3", text: /Required\s+2/)
      expect(page).to have_no_css(".review-group h3", text: "Optional")
    end
    expect(optional.reload.requirement).to eq("required")
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/review-manager-#{theme}.png"))
    end
    click_button "Close reviews", enable_aria_label: true
    within("#footnote-approvals") { expect(page).to have_css(".review-group h3", text: /Required\s+2/) }
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/review-preview/review-log-#{theme}.png"))
    end
  end

  it "jumps to a visible review log and counts only approvals of the current version" do
    indicator = find("[data-review-indicator]")
    expect(indicator[:title]).to include("0 of 1 required reviewers approved v1")
    indicator.click
    expect(page.evaluate_script("document.activeElement.id")).to eq("footnote-approvals")
    within("#footnote-approvals") do
      expect(page).to have_content("Activity")
      expect(page).to have_content("requested a review from Plan Reviewer")
    end
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    visit plan_page_path(plan)
    expect(find("[data-review-indicator]")[:title]).to include("1 of 1 required reviewers approved v1")
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "A revised contract")
    plan.update!(current_plan_version: version, current_revision: 2)
    visit plan_page_path(plan)
    expect(find("[data-review-indicator]")[:title]).to include("0 of 1 required reviewers approved v2")
    expect(page).to have_css("#footnote-approvals .review-history", text: /Plan Reviewer approved\s+v1/)
  end

  it "changes visibility through the byline without navigation or scroll jumps" do
    sign_in_browser(author)
    page.execute_script("window.scrollTo(0, 120)")
    scroll = page.evaluate_script("window.scrollY")
    click_button "Shared", exact: true
    within(".plan-visibility-panel") { click_button "Private", exact: false }
    expect(page).to have_button("Private", exact: true)
    expect(page).to have_css(".plan-visibility-button:focus", text: "Private")
    expect(plan.reload).to be_draft
    expect(page).to have_current_path(plan_page_path(plan))
    expect(page.evaluate_script("window.scrollY")).to eq(scroll)
    click_button "Private", exact: true
    within(".plan-visibility-panel") { click_button "Shared", exact: false }
    expect(page).to have_button("Shared", exact: true)
    expect(plan.reload).to be_published
  end

  it "shows visibility to readers without exposing author controls" do
    click_button "Shared", exact: true
    within(".plan-visibility-panel") do
      expect(page).to have_content("Listed for everyone in the organization.")
      expect(page).to have_no_button
    end
    expect(page).to have_css(".plan-visibility-panel:focus")
    page.send_keys(:escape)
    expect(page).to have_css(".plan-visibility-button:focus", text: "Shared")
  end

  it "preserves unsent feedback when an open review request is withdrawn" do
    within(".review-tray") { click_button "Request changes" }
    fill_in "Public review comment", with: "An unfinished review", enable_aria_label: true
    task.update!(status: "withdrawn")
    page.execute_script("document.getElementById('plan-review-controls').dispatchEvent(new CustomEvent('coplan:reviews-changed'))")
    expect(page).to have_content("This review request is no longer active. Your unsent feedback is still here.")
    expect(page).to have_field("Public review comment", with: "An unfinished review", enable_aria_label: true)
    within(".review-tray__discussion") { expect(page).to have_button("Request changes", disabled: true) }
    expect(page).to have_no_css(".review-tray__actions button", text: "Approve")
  end

  it "uses the existing dictation composer and keeps the bar within narrow screens in both themes" do
    within(".review-tray") { click_button "Request changes" }
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
