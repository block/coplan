require "capybara/rspec"

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :selenium_chrome_headless
  end
end

Capybara.server = :puma, { Silent: true }
