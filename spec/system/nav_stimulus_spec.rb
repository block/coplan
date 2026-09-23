require "rails_helper"

# Browser-level coverage for the chrome's Stimulus flows: the search and
# keyboard-shortcut modals, the inbox dropdown, and the theme switcher.
# Server responses for these are covered by request specs; these verify the
# JS wiring users actually use.
RSpec.describe "Navigation chrome", type: :system do
  let(:user) { create(:coplan_user, email: "navigator@example.com") }

  def sign_in(u)
    visit sign_in_path
    fill_in "Email address", with: u.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
  end

  before { sign_in(user) }

  describe "search modal" do
    let!(:plan) { create(:plan, :published, created_by_user: user, title: "Quarterly Payments Review") }

    it "opens with the / shortcut and shows typeahead results" do
      visit library_page_path(user)
      find("body").send_keys("/")
      expect(page).to have_css(".search-modal:popover-open")

      find(".search-modal__input").fill_in with: "Quarterly"
      expect(page).to have_link("Quarterly Payments Review", wait: 5)

      find("body").send_keys(:escape)
      expect(page).not_to have_css(".search-modal:popover-open")
    end

    it "opens from the header search button" do
      visit library_page_path(user)
      find(".site-nav__search").click
      expect(page).to have_css(".search-modal:popover-open")
    end
  end

  describe "keyboard shortcuts modal" do
    it "opens with ? and closes with Escape" do
      visit library_page_path(user)
      find("body").send_keys("?")

      expect(page).to have_css(".keyboard-shortcuts[open]")
      within(".keyboard-shortcuts[open]") do
        expect(page).to have_content("Keyboard shortcuts")
        expect(page).to have_content("Search plans and people")
        expect(page).to have_content("Next search result")
        expect(page).to have_content("Next open thread")
        expect(page).to have_content("Start presenting")
        expect(page).to have_content("Page Down")
      end

      find("body").send_keys(:escape)
      expect(page).not_to have_css(".keyboard-shortcuts[open]")
    end

    it "does not open while typing" do
      visit library_page_path(user)
      find(".site-nav__search").click
      field = find(".search-modal__input")
      field.send_keys("?")

      expect(page).not_to have_css(".keyboard-shortcuts[open]")
      expect(field.value).to include("?")
    end

    it "traps focus, blocks background shortcuts, and restores focus on close" do
      visit library_page_path(user)
      page.execute_script("document.querySelector('.site-nav__search').focus()")
      page.driver.browser.action.send_keys("?").perform
      expect(page).to have_css(".keyboard-shortcuts[open]")
      expect(page.evaluate_script("document.activeElement.getAttribute('aria-label')")).to eq("Close keyboard shortcuts")

      page.driver.browser.action.send_keys("/").send_keys(:tab).perform
      expect(page).not_to have_css(".search-modal:popover-open")
      expect(page.evaluate_script("document.activeElement.closest('dialog')?.id")).to eq("keyboard-shortcuts-modal")
      page.driver.browser.action.send_keys(:escape).perform
      expect(page).not_to have_css(".keyboard-shortcuts[open]")
      expect(page.evaluate_script("document.activeElement.matches('.site-nav__search')")).to be(true)
    end

    it "matches the catalog, ignores composition and modifiers, and refreshes after Turbo navigation" do
      visit library_page_path(user)
      # Replace the embedded catalog as a Turbo body replacement would.
      page.execute_script(<<~JS)
        const old = document.getElementById('coplan-shortcut-catalog');
        const replacement = old.cloneNode(true);
        const catalog = JSON.parse(old.textContent);
        catalog.help.bindings[0].keys = ['h'];
        replacement.textContent = JSON.stringify(catalog);
        old.replaceWith(replacement);
        document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'h', bubbles: true, isComposing: true}));
        document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'h', bubbles: true, ctrlKey: true}));
      JS
      expect(page).not_to have_css(".keyboard-shortcuts[open]")
      find("body").send_keys("?")
      expect(page).not_to have_css(".keyboard-shortcuts[open]")
      find("body").send_keys("h")
      expect(page).to have_css(".keyboard-shortcuts[open]")
      find("body").send_keys(:escape)

      page.execute_script("Turbo.visit(arguments[0])", settings_root_path)
      expect(page).to have_current_path(settings_root_path)
      find("body").send_keys("?")
      expect(page).to have_css(".keyboard-shortcuts[open]", count: 1)
    end

    it "lets a focused widget consume a key before page navigation" do
      create(:plan, :published, created_by_user: user)
      visit library_page_path(user)
      page.execute_script(<<~JS)
        const button = document.querySelector('.site-nav__search');
        button.addEventListener('keydown', event => event.preventDefault(), {once: true});
        button.focus();
      JS
      page.driver.browser.action.send_keys("j").perform
      expect(page).not_to have_css(".workspace-key-selected")
      find("body").send_keys("j")
      expect(page).to have_css(".workspace-key-selected")
    end
  end

  describe "inbox dropdown" do
    it "opens the panel, loads notifications, and closes on outside click" do
      thread = create(:comment_thread, plan: create(:plan, :published, created_by_user: user), created_by_user: user)
      create(:notification, user: user, plan: thread.plan, comment_thread: thread)

      visit library_page_path(user)
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
      find(".segmented__option", text: "Dark").click

      expect(page.evaluate_script("document.documentElement.getAttribute('data-theme')")).to eq("dark")
      expect(user.reload.theme_preference).to eq("dark")

      visit settings_root_path
      expect(page.evaluate_script("document.documentElement.getAttribute('data-theme')")).to eq("dark")
    end
  end
end
