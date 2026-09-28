require "rails_helper"

RSpec.describe "CoPlan administration", type: :request do
  it "requires a signed-in user" do
    get "/_/admin"

    expect(response).to redirect_to(sign_in_path)
  end

  it "rejects a signed-in non-admin" do
    sign_in_as(create(:coplan_user, admin: false))

    get "/_/admin"

    expect(response).to have_http_status(:forbidden)

    get "/_/admin/notification_deliveries"
    expect(response).to have_http_status(:forbidden)
  end

  it "shows engine resources to admins" do
    sign_in_as(create(:coplan_user, admin: true))

    get "/_/admin"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Notification delivery")

    get "/_/admin/notification_deliveries"
    expect(response).to have_http_status(:ok)

    get "/_/admin/notifications"
    expect(response).to have_http_status(:ok)
  end

  it "does not let an admin grant privileges through the shared users page" do
    admin = create(:coplan_user, admin: true)
    other = create(:coplan_user, admin: false)
    sign_in_as(admin)

    get "/_/admin/users/#{other.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Edit User")

    get "/_/admin/users/#{other.id}/edit"
    expect(response).to have_http_status(:not_found)

    patch "/_/admin/users/#{other.id}", params: { user: { admin: true } }
    expect(response).to have_http_status(:not_found)
    expect(other.reload.admin?).to be(false)

    post "/_/admin/users/batch_action", params: { batch_action: "destroy", collection_selection: [ other.id ] }
    expect(response).to have_http_status(:not_found)
    expect(CoPlan::User.exists?(other.id)).to be(true)
  end

  it "redirects the former admin URL to the shared admin area" do
    sign_in_as(create(:coplan_user, admin: true))

    get "/admin"

    expect(response).to redirect_to("/_/admin")
  end

  it "offers the shared admin area in the app menu only to admins" do
    user = create(:coplan_user, admin: true)
    sign_in_as(user)

    get "/_/home"
    expect(response.body).to include("Administration")

    user.update!(admin: false)
    get "/_/home"
    expect(response.body).not_to include("Administration")
  end

  it "counts a grouped delivery as one Slack message" do
    sign_in_as(create(:coplan_user, admin: true))
    2.times do
      create(:notification_delivery, status: "delivered", external_id: "slack-ts-1", sent_at: Time.current)
    end

    get "/_/admin"

    expect(response.body).to include("2 notification intents created", "Delivered: 2", "1 Slack message sent")
  end
end
