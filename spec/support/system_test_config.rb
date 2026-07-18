require "capybara/rspec"

RSpec.configure do |config|
  config.before(:each, type: :system) do
    # Explicit desktop size: the workspace sidebar collapses behind a
    # toggle below 56rem, so sidebar interactions need a wide viewport.
    # (Mobile-specific tests resize the window themselves.) Note
    # :selenium_chrome_headless is a Capybara-registered driver that
    # ignores screen_size — the :selenium/using form respects it.
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 900 ]
  end
end

Capybara.server = :puma, { Silent: true }
