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

    [ false, true ].each do |reduced_motion|
      it "focuses search immediately and reopens cleanly with #{reduced_motion ? 'reduced' : 'normal'} motion" do
        page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
          { name: "prefers-reduced-motion", value: reduced_motion ? "reduce" : "no-preference" }
        ])
        visit library_page_path(user)
        page.execute_script("document.body.style.minHeight = '2000px'; window.scrollTo(0, 600)")
        scroll = page.evaluate_script("scrollY")
        expect(scroll).to be > 0
        page.execute_script <<~JS
          window.searchAnimations = 0;
          const animate = Element.prototype.animate;
          Element.prototype.animate = function(...args) {
            if (this.id === 'search-modal') window.searchAnimations++;
            return animate.apply(this, args);
          };
        JS
        find(".site-nav__search").click
        expect(page).to have_css(".search-modal__input:focus")
        expect(page).to have_css(".search-modal__icon[aria-hidden='true']")
        find(".search-modal__input").send_keys(:escape)
        expect(page).not_to have_css(".search-modal:popover-open")
        page.driver.browser.action.send_keys("/").perform
        expect(page).to have_css(".search-modal__input:focus")
        expect(page.evaluate_script("window.searchAnimations")).to eq(reduced_motion ? 0 : 2)
        expect(page.evaluate_script("scrollY")).to eq(scroll)
      ensure
        page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
      end
    end

    it "announces the selected result while arrow keys keep focus in the search field" do
      alpha = create(:coplan_user, name: "Accessible Alpha")
      beta = create(:coplan_user, name: "Accessible Beta")
      visit library_page_path(user)
      find(".site-nav__search").click
      field = find_field("Search plans and people", enable_aria_label: true)
      field.fill_in with: "Accessible"

      within("#search-results-listbox[role='listbox']") do
        expect(page).to have_css("[role='group'][aria-label='People'] [role='option']", count: 2)
        expect(page).to have_css("[role='option'][aria-selected='true']", text: alpha.name)
      end
      expect(find("#search-modal [role='status']", visible: :all).text(:all)).to include("2 results available")
      expect(field["aria-controls"]).to eq("search-results-listbox")
      expect(field["aria-expanded"]).to eq("true")

      field.send_keys(:arrow_down)
      selected = find("#search-results [role='option'][aria-selected='true']")
      expect(selected).to have_text(beta.name)
      expect(field["aria-activedescendant"]).to eq(selected[:id])
      expect(page.evaluate_script("document.activeElement.matches('.search-modal__input')")).to be(true)

      field.send_keys(:arrow_down)
      expect(page).to have_css("#search-results [aria-selected='true']", text: alpha.name)
      field.send_keys(:arrow_up, :enter)
      expect(page).to have_current_path(library_page_path(beta))
    end

    it "clears the active result for an unmatched query and closes with one Escape" do
      create(:coplan_user, name: "Accessible Person")
      visit library_page_path(user)
      find(".site-nav__search").click
      field = find_field("Search plans and people", enable_aria_label: true)
      field.fill_in with: "Accessible"
      expect(page).to have_css("#search-results [aria-selected='true']")

      field.fill_in with: "nothingmatcheszzz"
      expect(page).to have_css("#search-results [data-search-summary]", text: "Nothing matches")
      expect(field["aria-activedescendant"]).to be_nil
      expect(field["aria-expanded"]).to eq("false")
      field.send_keys(:arrow_down, :escape)
      expect(page).not_to have_css(".search-modal:popover-open")
      expect(field["aria-activedescendant"]).to be_nil
    end

    it "keeps full-page results reachable as ordinary links with Tab and Enter" do
      person = create(:coplan_user, name: "Accessible Person")
      visit search_path(q: "Accessible")
      expect(page).to have_css("#search-page-results a[data-search-result]", text: person.name)
      find(".search-page__input").send_keys(:tab)
      expect(page.evaluate_script("document.activeElement.textContent")).to include(person.name)
      page.driver.browser.action.send_keys(:enter).perform
      expect(page).to have_current_path(library_page_path(person))
    end
  end

  describe "keyboard shortcuts modal" do
    %w[light dark].each do |theme|
      it "opens with ? and closes with Escape in #{theme} mode" do
        user.update!(theme_preference: theme)
        visit library_page_path(user)
        expect(page).to have_css("html[data-theme='#{theme}']")
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
      expect(page.evaluate_script("document.activeElement.id")).to eq("keyboard-shortcuts-title")

      page.driver.browser.action.send_keys("/").send_keys(:tab).perform
      expect(page.evaluate_script("document.activeElement.getAttribute('aria-label')")).to eq("Close keyboard shortcuts")
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

    it "blocks library navigation behind a popover even when focus is outside its input" do
      create(:plan, :published, created_by_user: user)
      visit library_page_path(user)
      find(".site-nav__search").click
      expect(page).to have_css(".search-modal:popover-open")
      # Exercise the overlay guard, not the separate text-entry guard.
      page.execute_script("document.activeElement.blur()")
      find("body").send_keys("j")
      expect(page).not_to have_css(".workspace-key-selected")
      expect(page).to have_css(".search-modal:popover-open")

      find("body").send_keys(:escape)
      expect(page).not_to have_css(".search-modal:popover-open")
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
    %w[light dark].each do |theme|
      it "keeps #{theme} and the voice hotkey after a host metadata refresh" do
        visit settings_root_path
        find(".segmented__option", text: theme.capitalize, exact_text: true).click
        find(".segmented__option", text: "Off", exact_text: true).click
        expect(page).to have_css("html[data-theme='#{theme}']")
        expect(page).to have_css('input[name="voice_hotkey"][value="off"]:checked', visible: :all)
        expect(page).not_to have_css('[data-coplan--voice-hotkey-target="error"]', visible: true)
        # Wait on persistence rather than racing the fetch with the host write.
        Timeout.timeout(5) do
          sleep 0.01 until user.reload.theme_preference == theme && user.voice_hotkey == "off"
        end
        user.update!(metadata: { "department" => "Engineering" })

        visit settings_root_path
        expect(page).to have_css("html[data-theme='#{theme}']")
        expect(page).to have_css("input[name='theme'][value='#{theme}']:checked", visible: :all)
        expect(page).to have_css('input[name="voice_hotkey"][value="off"]:checked', visible: :all)
      end
    end

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
