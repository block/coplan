require "rails_helper"

RSpec.describe "Missing pages", type: :request do
  it "offers a public, real 404 in the regular layout" do
    get "/_/not-found"
    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("Page not found", "Take a puzzle break")
    expect(response.parsed_body.at_css('.site-nav__brand')["href"]).to eq("/")
    expect(response.parsed_body.css('.lost-page a')).to be_empty
    expect(response.body).to include('name="robots" content="noindex"')
    expect(response.parsed_body.at_css(".site-nav .site-nav__logo")).to be_present
    expect(response.parsed_body.at_css(".main-content .lost-page")).to be_present
  end

  it "keeps navigation under the engine mount" do
    get "/_/not-found", env: { "SCRIPT_NAME" => "/coplan" }
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.at_css('.site-nav__brand')["href"]).to eq("/coplan/")
  end

  it "does not send a game to non-HTML clients" do
    get "/_/not-found", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
  end

  context "when signed in" do
    let(:user) { create(:coplan_user, theme_preference: "dark") }
    before { sign_in_as(user) }

    it "retains the signed-in navigation and theme on the public preview" do
      get "/_/not-found"
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('data-theme="dark"')
      expect(response.parsed_body.at_css(".site-nav__search")).to be_present
      expect(response.parsed_body.at_css(".site-nav__bell")).to be_present
      expect(response.parsed_body.at_css("#nav-menu")).to be_present
    end

    it "renders missing readable URLs with the viewer's theme" do
      get "/nobody-here/missing-document"
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("Make a way back.", 'data-theme="dark"')
    end

    it "renders missing record URLs too" do
      get "/plans/does-not-exist"
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("Make a way back.")
    end

    it "keeps missing Markdown responses empty" do
      get "/nobody-here/missing-document.md"
      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_empty
    end
  end

  it "uses the host exceptions app for routing errors without detailed diagnostics" do
    previous = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    get "/_/not-a-route"
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.at_css("#game-title")&.text).to eq("Make a way back.")

    get "/_/not-a-route", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to include("status" => 404, "error" => "Not Found")
  ensure
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = previous
  end
end
