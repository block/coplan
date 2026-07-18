require "rails_helper"

# Browser-level coverage for the chrome's Stimulus flows: the search modal
# (popover + typeahead), the inbox dropdown, and the theme switcher. Server
# responses for these are covered by request specs; these verify the JS
# wiring users actually click.
RSpec.describe "Navigation chrome", type: :system do
  let(:user) { create(:coplan_user, email: "navigator@example.com") }

  def sign_in(u)
    visit sign_in_path
    fill_in "Email address", with: u.email
    click_button "Sign In"
    expect(page).to have_content("Sign out")
  end

  before { sign_in(user) }

  describe "search modal" do
    let!(:plan) { create(:plan, :published, created_by_user: user, title: "Quarterly Payments Review") }

    it "opens with the / shortcut and shows typeahead results" do
      visit plans_path
      find("body").send_keys("/")
      expect(page).to have_css(".search-modal:popover-open")

      find(".search-modal__input").fill_in with: "Quarterly"
      expect(page).to have_link("Quarterly Payments Review", wait: 5)

      find("body").send_keys(:escape)
      expect(page).not_to have_css(".search-modal:popover-open")
    end

    it "opens from the header search button" do
      visit plans_path
      find(".site-nav__search").click
      expect(page).to have_css(".search-modal:popover-open")
    end
  end

  describe "inbox dropdown" do
    it "opens the panel, loads notifications, and closes on outside click" do
      thread = create(:comment_thread, plan: create(:plan, :published, created_by_user: user), created_by_user: user)
      create(:notification, user: user, plan: thread.plan, comment_thread: thread)

      visit plans_path
      find(".site-nav__bell").click
      expect(page).to have_css(".inbox-panel", visible: :visible)
      expect(find(".site-nav__bell")["aria-expanded"]).to eq("true")

      # Click far from the panel (it hangs under the right side of the nav).
      find(".workspace__sidebar").click
      expect(page).to have_css(".inbox-panel", visible: :hidden)
    end
  end

  describe "theme switcher" do
    it "applies the chosen theme immediately and persists it across reload" do
      visit settings_root_path
      find(".theme-switcher__option", text: "Dark").click

      expect(page.evaluate_script("document.documentElement.getAttribute('data-theme')")).to eq("dark")
      expect(user.reload.theme_preference).to eq("dark")

      visit settings_root_path
      expect(page.evaluate_script("document.documentElement.getAttribute('data-theme')")).to eq("dark")
    end
  end
end
