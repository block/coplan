# Extend the gem's early head snippet without shipping test instrumentation as
# a production asset. Both the host and engine layouts use the same helper.
module BrowserSynchronization
  SCRIPT = File.read(File.join(__dir__, "browser_synchronization.js")).freeze

  def capybara_lockstep_js(options = {})
    super + "\n" + SCRIPT
  end
end

Capybara::Lockstep::Helper.prepend(BrowserSynchronization)
Capybara::Lockstep.timeout = 15
Capybara::Lockstep.timeout_with = :error

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
