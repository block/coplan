require "rails_helper"
require "coplan/development_seed"

RSpec.describe "Demo library", type: :system do
  it "signs in with the default author and browses the shared examples" do
    CoPlan::DevelopmentSeed.call
    allow(Rails.env).to receive(:development?).and_return(true)

    visit "/sign_in"
    expect(page).to have_field("Email address", with: "hampton@example.com")
    CoPlan::DevelopmentSeed::USERS.each do |definition|
      expect(page).to have_selector("button", text: "#{definition.fetch(:key)}@example.com")
    end
    [ "light", "dark" ].each do |theme|
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia",
        features: [ { name: "prefers-color-scheme", value: theme } ])
      expect(page).to have_button("hampton@example.com Default owner · Admin")
      page.save_screenshot(Rails.root.join("tmp/demo-library/login-#{theme}.png"))
    end
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    click_button "Sign In"
    expect(page).to have_current_path("/hampton")
    expect(page).to have_content("Hampton")

    visit "/hampton/demo-library"
    expect(page).to have_content("One version, no edits, no comments, no reviewers")
    click_link "Workspace invitations: first draft", match: :first
    expect(page).to have_content("Send workspace invitations through a durable outbox")
    expect(page).to have_content("Workspace invitations: first draft")
  end

  it "signs in as a reviewer directly from the demo account list" do
    CoPlan::DevelopmentSeed.call
    allow(Rails.env).to receive(:development?).and_return(true)

    visit "/sign_in"
    click_button "noura@example.com Security Engineer"
    expect(page).to have_current_path("/noura")
    expect(page).to have_content("Noura Haddad")
  end

  [ "light", "dark" ].each do |theme|
    it "opens real node and edge discussions from the content library in #{theme} mode" do
      CoPlan::DevelopmentSeed.call
      owner = CoPlan::User.find_by!(email: "hampton@example.com")
      owner.update!(theme_preference: theme)
      visit "/sign_in"
      fill_in "Email address", with: owner.email
      click_button "Sign In"
      expect(page).to have_current_path("/hampton")
      visit "/hampton/demo-library"
      expect(page).to have_content("Every plan type")
      expect(page).to have_content("Scratchpad")
      expect(page).to have_content("Test Plan")
      page.save_screenshot(Rails.root.join("tmp/demo-library/content-index-#{theme}.png"))
      click_link "Flowchart: comment on nodes and connections", exact: true
      expect(page).to have_css(".mermaid-diagram g.node[data-source-target]", count: 4, wait: 20)
      find('.mermaid-diagram g.node[aria-label^="Node Queue."] .source-thread-badge').click
      expect(page).to have_css(".source-comments", text: "Should this queue have a separate retry budget per workspace?")
      page.save_screenshot(Rails.root.join("tmp/demo-library/flowchart-comments-#{theme}.png"))
      find('.source-comments [aria-label="Close element comments"]').click
      find(".mermaid-diagram .source-edge-badges .source-thread-badge").click
      expect(page).to have_css(".source-comments", text: "What backoff do we use on this retry connection?")
    end
  end

  it "shows one slide and multiple independent decks mixed with prose" do
    CoPlan::DevelopmentSeed.call
    visit "/sign_in"
    fill_in "Email address", with: "hampton@example.com"
    click_button "Sign In"
    expect(page).to have_current_path("/hampton")
    visit "/hampton/demo-library"
    click_link "One slide: the workspace launch decision", exact: true
    expect(page).to have_css(".deck-region", count: 1)
    expect(page).to have_css(".deck-toolbar__count[data-count='1 / 1']")
    visit "/hampton/demo-library"
    click_link "Mixed document: prose and two embedded decks", exact: true
    expect(page).to have_css(".deck-region", count: 2)
    expect(page).to have_content("Implementation notes between decks")
    expect(page).to have_content("Follow-up after the decks")
    first, second = all(".deck-region")
    expect(first).to have_css(".deck-toolbar__count[data-count='1 / 3']")
    expect(second).to have_css(".deck-toolbar__count[data-count='1 / 2']")
    first.find(".deck-toolbar__step--next").click
    expect(first).to have_css(".mermaid-diagram svg", wait: 20)
    expect(second).to have_css(".deck-toolbar__count[data-count='1 / 2']")
    page.save_screenshot(Rails.root.join("tmp/demo-library/mixed-content.png"))
  end
end
