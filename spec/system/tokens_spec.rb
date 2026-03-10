require "rails_helper"

RSpec.describe "Token management", type: :system do
  before do
    visit sign_in_path
    fill_in "Email address", with: "testuser@example.com"
    click_button "Sign In"
    expect(page).to have_content("Sign out")
  end

  it "creates a token and displays the raw value via Turbo Stream" do
    visit settings_tokens_path

    # Verify no token reveal is shown initially
    expect(page).not_to have_css(".token-reveal")

    fill_in "Token Name", with: "My Test Token"
    click_button "Create Token"

    # The token reveal should appear without a full page reload
    expect(page).to have_css(".token-reveal")
    expect(page).to have_content("Your new API token")
    expect(page).to have_content("Copy this token now")

    # The raw token value should be a 64-char hex string
    token_code = find(".token-reveal__value code")
    expect(token_code.text).to match(/\A[0-9a-f]{64}\z/)

    # The new token should appear in the table
    expect(page).to have_content("My Test Token")

    # The form should be reset and ready for another token
    expect(find_field("Token Name").value).to be_blank
  end

  it "creates a token when no tokens exist yet (empty state)" do
    visit settings_tokens_path

    # Table should be empty
    expect(page).not_to have_css("#tokens-list tr")

    fill_in "Token Name", with: "First Token"
    click_button "Create Token"

    # Token reveal and table row should both appear
    expect(page).to have_css(".token-reveal")
    expect(page).to have_content("First Token")
    expect(page).to have_css("#tokens-list tr", count: 1)
  end

  it "revokes a token via Turbo Stream" do
    user = CoPlan::User.find_by!(email: "testuser@example.com")
    create(:api_token, user: user, name: "Revokable")

    visit settings_tokens_path
    expect(page).to have_content("Revokable")
    expect(page).to have_css(".badge--success")

    click_button "Revoke"

    # Should update in-place to show revoked state
    expect(page).to have_css(".badge--danger")
    expect(page).not_to have_button("Revoke")

    # Token name should still be visible (not removed from page)
    expect(page).to have_content("Revokable")
  end
end
