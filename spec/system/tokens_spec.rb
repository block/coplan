require "rails_helper"

RSpec.describe "Token management", type: :system do
  before do
    visit sign_in_path
    fill_in "Email address", with: "testuser@example.com"
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")
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
    expect(page).to have_css(".badge--neutral")
    expect(page).not_to have_button("Revoke")

    # Token name should still be visible (not removed from page)
    expect(page).to have_content("Revokable")
  end

  it "browses and searches session history in place, then revokes valid access" do
    user = CoPlan::User.find_by!(email: "testuser@example.com")
    create(:api_token, user: user, name: "Review session", agent_name: "Claude",
      expires_at: 1.day.from_now, metadata: { harness: "claude-code", model: "demo-model" })
    create(:api_token, user: user, name: "Another session", expires_at: 1.day.from_now)
    26.times { |i| create(:api_token, user: user, name: "Past session #{i}", expires_at: 1.day.ago) }
    visit settings_agent_sessions_path
    expect(page).to have_content("Review session")
    page.execute_script("window.tokenPageMarker = 'same-page'")
    click_link "History (26)"
    expect(page).to have_css("#sessions-list tr", count: 25)
    expect(page).not_to have_button("Revoke")
    click_link "Next →"
    expect(page).to have_content("Page 2")
    expect(page).to have_css("#sessions-list tr", count: 1)
    click_link "Valid access (2)"
    expect(page).to have_content("Another session")
    expect(page).to have_css("#sessions-list tr", count: 2)
    fill_in "Search sessions", with: "demo-model"
    click_button "Search"
    expect(page).to have_css("#sessions-list tr", count: 1)
    expect(page).to have_content("Review session")
    expect(page.evaluate_script("window.tokenPageMarker")).to eq("same-page")
    within(find("#sessions-list tr", text: "Review session")) { click_button "Revoke" }
    expect(page).to have_content("Session access revoked.")
    expect(page).to have_link("Valid access (1)")
    expect(page).not_to have_content("Review session")
    click_link "History (27)"
    expect(page).to have_content("Review session")
    expect(page).not_to have_button("Revoke")
  end

  %w[light dark].each do |theme|
    it "keeps agent access contained and readable in #{theme} mode" do
      user = CoPlan::User.find_by!(email: "testuser@example.com")
      user.update!(theme_preference: theme)
      parent = create(:api_token, user: user, name: "Work laptop")
      create(:api_token, user: user, parent: parent, name: "Design review", agent_name: "Claude",
        expires_at: 1.day.from_now, metadata: { harness: "claude-code", model: "Demo model" })
      create(:api_token, user: user, name: "Research", expires_at: 1.day.from_now)
      visit settings_root_path
      expect(page).to have_content("2 agent sessions with valid access")
      expect(page).not_to have_button("Create Token")
      labels = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll('.settings-row__label')).map(label => label.getBoundingClientRect().left)
      JS
      expect(labels.max - labels.min).to be < 1
      page.save_screenshot(Rails.root.join("tmp/agent-access/settings-#{theme}.png"))
      click_link "Manage agent sessions"
      expect(page).to have_content("Design review")
      expect(page).to have_content("Harness not reported")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true
      page.save_screenshot(Rails.root.join("tmp/agent-access/sessions-#{theme}.png"))
      page.current_window.resize_to(390, 844)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true
      page.save_screenshot(Rails.root.join("tmp/agent-access/sessions-mobile-#{theme}.png"))
    ensure
      page.current_window.resize_to(1400, 900)
    end
  end

  %i[settings_tokens_path].each do |route|
    %w[light dark].each do |theme|
      it "keeps #{route} within a narrow viewport and lets the table scroll by keyboard in #{theme} mode" do
        user = CoPlan::User.find_by!(email: "testuser@example.com")
        user.update!(theme_preference: theme)
        create(:api_token, user: user, name: "A long descriptive development agent token name")
        page.driver.browser.manage.window.resize_to(320, 720)
        visit public_send(route)
        expect(page).to have_content("Your personal tokens")
        expect(find(".site-nav__brand").native.accessible_name).to eq("CoPlan")
        expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)

        table_region = find(".data-table-scroll[aria-labelledby='tokens-heading']")
        expect(page).to have_css("#tokens-card th", text: "Actions", visible: :all)
        expect(page.evaluate_script("document.querySelector('.data-table-scroll').scrollWidth > document.querySelector('.data-table-scroll').clientWidth")).to be(true)
        table_region.send_keys(*Array.new(10, :arrow_right))
        Timeout.timeout(Capybara.default_max_wait_time) do
          sleep 0.01 until page.evaluate_script("document.querySelector('.data-table-scroll').scrollLeft > 0")
        end
        expect(page.evaluate_script("document.querySelector('.data-table-scroll').scrollLeft")).to be > 0
        expect(page.evaluate_script("scrollX")).to eq(0)
      ensure
        page.driver.browser.manage.window.resize_to(1400, 900)
      end
    end
  end
end
