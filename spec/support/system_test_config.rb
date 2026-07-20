require "capybara/rspec"

# Make selenium-manager provision Chrome for Testing instead of picking up
# the system Chrome (see the note on driven_by below). Cached after the
# first download, so this doesn't hit the network on every run.
ENV["SE_FORCE_BROWSER_DOWNLOAD"] ||= "true"

RSpec.configure do |config|
  config.before(:each, type: :system) do
    # Explicit desktop size: the workspace sidebar collapses behind a
    # toggle below 56rem, so sidebar interactions need a wide viewport.
    # (Mobile-specific tests resize the window themselves.) Note
    # :selenium_chrome_headless is a Capybara-registered driver that
    # ignores screen_size — the :selenium/using form respects it.
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 900 ] do |options|
      # Use Chrome for Testing (provisioned by selenium-manager), NOT the
      # system Chrome. On managed machines the system Chrome is enrolled in
      # Chrome Browser Cloud Management, which force-installs IT extensions
      # into every profile — even chromedriver's temp one, even with
      # --disable-extensions. One of them opens a background Marketplace tab
      # ~20s after launch, which Capybara's teardown then hangs 20s trying to
      # close, failing whichever spec happens to be running. Chrome for
      # Testing has a different bundle ID, so managed policies never apply.
      # Pinned to a major version for reproducibility (151 also introduced a
      # doubled-navigation behavior that races Capybara's visit).
      options.browser_version = "150"
      # CI runners give /dev/shm a small tmpfs; Chrome uses it for shared
      # memory and dies mid-suite when it fills ("Chrome instance exited"
      # at session creation). Spill to /tmp instead — harmless locally.
      options.add_argument("--disable-dev-shm-usage")
    end
  end
end

Capybara.server = :puma, { Silent: true }
