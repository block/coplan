require "rails_helper"

RSpec.describe "Missing-page puzzle", type: :system do
  it "keeps header navigation usable without JavaScript" do
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    visit "/_/not-found"
    find("summary[aria-label='Take a puzzle break']").click
    expect(page).to have_text("The puzzle needs JavaScript.")
    expect(page).to have_button("Start over", disabled: true)
    find(".site-nav__brand").click
    expect(page).to have_current_path("/")
  ensure
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
  end

  it "fits phone screens and respects light, dark, and reduced-motion preferences" do
    user = create(:coplan_user, email: "missing-page@example.com", theme_preference: "system")
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_css(".site-nav__menu-btn")
    visit settings_root_path
    expect(page).to have_button("Menu")
    nav_width = page.evaluate_script("document.querySelector('.site-nav__inner').getBoundingClientRect().width")
    font = page.evaluate_script("getComputedStyle(document.documentElement).fontFamily")
    visit "/_/not-found"
    find("summary[aria-label='Take a puzzle break']").click
    expect(page).to have_button("Start over")
    expect(page).to have_button("Menu")
    expect(page).to have_css(".site-nav__bell")
    find("summary[aria-label='Take a puzzle break']").click
    expect(page).not_to have_css(".lost-game", visible: true)
    expect(page.evaluate_script("document.querySelector('.site-nav__inner').getBoundingClientRect().width")).to eq(nav_width)
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.lost-page')).fontFamily")).to eq(font)
    find(".site-nav__search").click
    expect(page).to have_css("#search-modal:popover-open")
    find(".search-modal__input").send_keys(:escape)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 1280, height: 900, deviceScaleFactor: 1, mobile: false)
    %w[light dark].each do |theme|
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
        { name: "prefers-color-scheme", value: theme },
        { name: "prefers-reduced-motion", value: "reduce" }
      ])
      expect(page.evaluate_script("getComputedStyle(document.documentElement).colorScheme")).to eq(theme)
      expect(page.evaluate_script("getComputedStyle(document.querySelector('.lost-game__tile svg')).transitionDuration")).to eq("0s")
      page.driver.browser.execute_async_script("const done = arguments[0]; Promise.all([...document.querySelectorAll('.btn')].filter(el => el.checkVisibility()).flatMap(el => el.getAnimations()).map(a => a.finished.catch(() => {}))).then(done)")
      page.save_screenshot(Rails.root.join("tmp/screenshots/404-final-#{theme}.png"))
    end
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    expect(page.evaluate_script("innerWidth")).to eq(390)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
    page.save_screenshot(Rails.root.join("tmp/screenshots/404-final-mobile.png"))
    find("summary[aria-label='Take a puzzle break']").click
    expect(page.evaluate_script("document.querySelector('.lost-game__tile').getBoundingClientRect().width")).to be >= 44
    find(".lost-game__tile", match: :first).click
    expect(page).to have_text("1 turn")
    screenshot = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: 390, height: page.evaluate_script("document.documentElement.scrollHeight"), scale: 1 })
    File.binwrite(Rails.root.join("tmp/screenshots/404-final-mobile-dark.png"), Base64.decode64(screenshot.fetch("data")))
  ensure
    # Capybara reuses Chrome; viewport/media emulation survives session resets.
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  it "connects a path, announces success, and resets without navigating" do
    visit "/_/not-found"
    find("summary[aria-label='Take a puzzle break']").click
    expect(page).to have_button("Start over")
    tiles = all(".lost-game__tile")
    # Solve the actual route, leaving all decoy tiles alone.
    { 0 => 1, 1 => 1, 5 => 2, 6 => 2, 10 => 2, 9 => 3, 13 => 3, 14 => 1, 15 => 1 }.each do |index, turns|
      turns.times { tiles[index].click }
    end
    expect(page).to have_text("Route found!")
    expect(page).to have_text("16 turns")
    expect(page).to have_css(".lost-game__tile.is-connected", count: 9)
    expect(page).to have_current_path("/_/not-found")
    tiles.first.click
    expect(page).to have_text("16 turns")
    click_button "Start over"
    expect(page).to have_text("0 turns")
    expect(page).not_to have_text("Route found!")
    expect(page).not_to have_css(".lost-game__tile.is-connected")
  end

  it "supports keyboard navigation and rotation without stealing page-level keys" do
    visit "/_/not-found"
    find("summary[aria-label='Take a puzzle break']").click
    expect(page).to have_button("Start over")
    first = find(".lost-game__tile", match: :first)
    first.send_keys(:arrow_right)
    expect(page).to have_css(".lost-game__tile:nth-child(2):focus")
    page.driver.browser.action.send_keys(:enter).perform
    expect(page).to have_text("1 turn")
    page.driver.browser.action.send_keys(:arrow_down).perform
    expect(page).to have_css(".lost-game__tile:nth-child(6):focus")
    find(".site-nav__brand").click
    expect(page).to have_current_path("/")
  end
end
