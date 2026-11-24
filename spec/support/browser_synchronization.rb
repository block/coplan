# Extend the gem's early head snippet without shipping test instrumentation as
# a production asset. Both the host and engine layouts use the same helper.
module BrowserSynchronization
  SCRIPT = File.read(File.join(__dir__, "browser_synchronization.js")).freeze

  def capybara_lockstep_js(options = {})
    super + "\n" + SCRIPT
  end
end

Capybara::Lockstep::Helper.prepend(BrowserSynchronization)
# Keep the gem's timeout behavior: a document replacement can discard a probe;
# it logs that timeout and tries again on the next command. Assertions still fail
# normally when their expected result does not arrive.
Capybara::Lockstep.debug = true if ENV["BROWSER_SYNC_DEBUG"] == "1"

# ActiveAdmin owns a separate layout. Wrap its head only in this test host.
ActionController::Base.prepend_view_path(File.join(__dir__, "views"))

RSpec.configure do |config|
  # Loading/progress regressions intentionally inspect unfinished work. Keep
  # their normal Capybara assertions, but don't wait for the held request.
  config.around(:each, type: :system) do |example|
    Capybara::Lockstep.mode = example.metadata.fetch(:browser_sync, :auto)
    example.run
  ensure
    Capybara::Lockstep.mode = :auto
  end
end
