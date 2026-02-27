require "rails_helper"

RSpec.describe "Sessions", type: :request do
  let!(:alice) { create(:coplan_user, :admin, email: "alice@acme.com", external_id: "alice@acme.com", name: "Alice") }

  it "sign in page renders" do
    get sign_in_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include("email")
  end

  it "sign in with valid email creates session" do
    post sign_in_path, params: { email: "alice@acme.com" }
    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response).to have_http_status(:success)
    expect(response.body).to include("Alice")
  end

  it "sign in creates new user if not exists" do
    expect {
      post sign_in_path, params: { email: "newuser@acme.com" }
    }.to change(CoPlan::User, :count).by(1)
    expect(response).to redirect_to(root_path)
  end

  it "sign out clears session" do
    post sign_in_path, params: { email: "alice@acme.com" }
    delete sign_out_path
    expect(response).to redirect_to(sign_in_path)

    get root_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "unauthenticated access returns unauthorized" do
    get root_path
    expect(response).to have_http_status(:unauthorized)
  end
end
