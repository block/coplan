require "rails_helper"

RSpec.describe "Coplan administration", type: :system do
  it "permanently deletes a soft-deleted comment in place after explicit confirmation" do
    user = create(:coplan_user, admin: true, email: "admin-deletion@example.com")
    comment = create(:comment, body_markdown: "Retained for administrator review")
    comment.soft_delete!
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)

    visit admin_plan_comment_path(comment)
    expect(page).to have_content("Retained for administrator review")
    page.execute_script("window.deletionPageMarker = 'same-page'")
    fill_in "Type DELETE to confirm permanent deletion", with: "DELETE"
    click_button "Permanently delete comment"

    expect(page).to have_content("Comment permanently deleted.")
    expect(page).not_to have_content("Retained for administrator review")
    expect(page.evaluate_script("window.deletionPageMarker")).to eq("same-page")
    expect(CoPlan::Comment.exists?(comment.id)).to be(false)
  end

  it "opens the shared dashboard and delivery history from the app menu" do
    user = create(:coplan_user, admin: true, email: "admin-browser@example.com")
    visit sign_in_path
    fill_in "Email address", with: user.email
    expect(page).to have_field("Email address", with: user.email)
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")

    click_button "Menu"
    click_link "Administration"
    expect(page).to have_current_path("/_/admin")
    expect(page.evaluate_script("typeof CapybaraLockstep")).to eq("object")
    expect(page).to have_content("Notification delivery · last 7 days")

    click_link "View delivery attempts"
    expect(page).to have_current_path("/_/admin/notification_deliveries")
    expect(page).to have_content("Notification Deliveries")
  end

  it "filters agent sessions and opens the matching record" do
    user = create(:coplan_user, admin: true, email: "admin-filter@example.com")
    plan = create(:plan, created_by_user: user)
    watching = CoPlan::AgentSession.create!(
      plan: plan, api_token: create(:api_token, user: user), agent_name: "Watching agent", state: "watching"
    )
    complete = CoPlan::AgentSession.create!(
      plan: plan, api_token: create(:api_token, user: user), agent_name: "Complete agent", state: "complete"
    )

    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path("/#{user.library.handle}")
    expect(page).to have_button("Menu")

    visit admin_agent_sessions_path
    expect(page).to have_content(watching.id)
    expect(page).to have_content(complete.id)

    fill_in "State", with: "watching"
    click_button "Filter"
    expect(page).to have_current_path(/q%5Bstate_cont%5D=watching/)
    expect(page).to have_content(watching.id)
    expect(page).not_to have_content(complete.id)

    click_link watching.id
    expect(page).to have_current_path(admin_agent_session_path(watching))
    expect(page).to have_content("Watching agent")
    expect(page).to have_content(watching.id)
  end
end
