require "rails_helper"

RSpec.describe "Web push settings", type: :system do
  let(:user) { create(:coplan_user, email: "push-settings@example.com") }

  before do
    allow(CoPlan.configuration).to receive(:web_push_configured?).and_return(true)
    allow(CoPlan.configuration).to receive(:vapid_public_key).and_return("dGVzdC1rZXk")
  end

  %w[light dark].each do |theme|
    it "enables and disables notifications through the mounted route in #{theme} mode" do
      user.update!(theme_preference: theme)
      visit sign_in_path
      fill_in "Email address", with: user.email
      click_button "Sign In"
      expect(page).to have_button("Menu")

      # Keep these browser API fakes across a Turbo visit. The fetch calls
      # themselves still reach Rails, so this exercises the URL used by JS.
      page.execute_script(<<~JS)
        window.PushManager = function PushManager() {};
        window.Notification = {
          permission: "default",
          requestPermission: async () => "granted"
        };
        const subscription = {
          toJSON: () => ({
            endpoint: "https://push.example.test/subscriptions/browser-1",
            keys: { p256dh: "public-key", auth: "auth-key" }
          }),
          unsubscribe: async () => { window.coplanTestSubscription = null; return true }
        };
        const registration = {
          pushManager: {
            getSubscription: async () => window.coplanTestSubscription || null,
            subscribe: async () => { window.coplanTestSubscription = subscription; return subscription }
          }
        };
        Object.defineProperty(navigator, "serviceWorker", {
          configurable: true,
          value: {
            getRegistration: async () => registration,
            register: async () => registration,
            ready: Promise.resolve(registration)
          }
        });
      JS

      page.execute_script("Turbo.visit(arguments[0])", settings_root_path)
      expect(page).to have_current_path(settings_root_path)
      expect(page).to have_css("html[data-theme='#{theme}']")
      expect(page).to have_css("meta[name='coplan-web-push-subscription-url'][content='#{web_push_subscription_path}']", visible: :all)

      click_button "Enable on this device"
      expect(page).to have_content("Notifications enabled on this device.")
      expect(user.web_push_subscriptions.count).to eq(1)

      click_button "Disable on this device"
      expect(page).to have_content("Notifications disabled on this device.")
      expect(user.web_push_subscriptions.count).to eq(0)
    end
  end
end
