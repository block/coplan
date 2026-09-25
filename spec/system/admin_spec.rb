require "rails_helper"

RSpec.describe "CoPlan administration", type: :system do
  it "opens the shared dashboard and delivery history from the app menu" do
    user = create(:coplan_user, admin: true, email: "admin-browser@example.com")
    visit sign_in_path
    fill_in "Email address", with: user.email
    expect(page).to have_field("Email address", with: user.email)
    click_button "Sign In"
    expect(page).to have_button("Menu")

    click_button "Menu"
    click_link "Administration"
    expect(page).to have_current_path("/_/admin")
    expect(page).to have_content("Notification delivery · last 7 days")

    click_link "View delivery attempts"
    expect(page).to have_current_path("/_/admin/notification_deliveries")
    expect(page).to have_content("Notification Deliveries")
  end
end
