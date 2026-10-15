require "rails_helper"

RSpec.describe "Sessions", type: :request do
  let!(:alice) { create(:coplan_user, :admin, email: "alice@acme.com", external_id: "alice@acme.com", name: "Alice") }

  it "sign in page renders" do
    get sign_in_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include("email")
  end

  it "prefills the seeded demo author only in development" do
    create(:coplan_user, external_id: "seed:hampton", email: "hampton@example.com", name: "Hampton")
    create(:coplan_user, external_id: "seed:alex", email: "alex@example.com", name: "Alex Morgan")
    allow(Rails.env).to receive(:development?).and_return(true)

    get sign_in_path
    expect(response.body).to include('value="hampton@example.com"', "Demo library", "Demo accounts", "alex@example.com")
    expect(response.body).not_to include("alice@acme.com")

    allow(Rails.env).to receive(:development?).and_return(false)
    get sign_in_path
    expect(response.body).not_to include('value="hampton@example.com"', "Try the demo as", "Demo accounts", "alex@example.com")
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

    # A library page is auth-gated; / (welcome) is intentionally public
    # per CIRCLE-49.
    get library_page_path(alice)
    expect(response).to redirect_to(sign_in_path)
  end

  it "unauthenticated access to a protected page redirects to sign in" do
    # A library page requires authentication; / (welcome) is the public
    # landing page.
    get library_page_path(alice)
    expect(response).to redirect_to(sign_in_path)
  end

  it "clears a pending sign-in prompt after authentication" do
    get library_page_path(alice)
    expect(response).to redirect_to(sign_in_path)
    expect(flash[:alert]).to eq("Please sign in.")

    # Turbo may serve the sign-in page from its cache, leaving this redirect's
    # flash pending when the form posts to the server.
    post sign_in_path, params: { email: alice.email }
    expect(flash[:alert]).to be_nil
    follow_redirect!
    expect(response.body).not_to include("Please sign in.")

    get library_page_path(alice)
    expect(response.body).not_to include("Please sign in.")
  end

  it "unauthenticated access to / renders the public landing page" do
    get root_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Design docs, built for AI-assisted planning")
  end
end
