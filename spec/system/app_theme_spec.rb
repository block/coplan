require "rails_helper"

# The app theme (docs/THEMES.md): picked in Settings, applied without a
# reload, and Neutral's reading look. Classic is covered by every other
# system spec, which runs with the default theme.
RSpec.describe "App themes", type: :system do
  let(:user) { create(:coplan_user, email: "theme-picker@example.com") }
  let(:content) do
    <<~MD
      # Durable outbox

      Partner webhooks leave the request **that caused them**.

      ## Design

      Write one row per event and deliver it later.

      ### Rows

      Each row holds the event and its payload.

      ```ruby
      Outbox.create!(event: "order.paid")
      ```
    MD
  end
  let(:plan) do
    create(:plan, :published, title: "Durable outbox", created_by_user: user).tap do |p|
      p.current_plan_version.update_columns(content_markdown: content)
    end
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  def app_theme_attribute = page.evaluate_script("document.documentElement.dataset.appTheme")

  def style(selector, property, pseudo = nil)
    page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json}), #{pseudo.to_json}).getPropertyValue(#{property.to_json})")
  end

  before { sign_in(user) }

  it "switches the theme as it's picked, saves it, and resolves Default to the site default" do
    visit settings_root_path
    expect(page).to have_css(".segmented__option:has(input:checked)", text: "Default (Classic)")
    expect(app_theme_attribute).to eq("classic")
    page.execute_script("window.themeChanges = 0; window.addEventListener('coplan:theme-changed', () => window.themeChanges++)")

    find(".segmented__option", text: "Neutral").click

    expect(app_theme_attribute).to eq("neutral")
    expect(page.evaluate_script("window.themeChanges")).to eq(1)
    expect(style("body", "font-family")).to start_with("system-ui")
    Timeout.timeout(5) { sleep 0.1 until user.reload.app_theme == "neutral" }

    visit settings_root_path
    expect(page).to have_css(".segmented__option:has(input:checked)", text: "Neutral")
    expect(app_theme_attribute).to eq("neutral")

    find(".segmented__option", text: "Default (Classic)").click
    expect(app_theme_attribute).to eq("classic")
    Timeout.timeout(5) { sleep 0.1 until user.reload.app_theme == "default" }
  end

  it "puts the old choice back when the save fails" do
    visit settings_root_path
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.fetch = (url, options) => String(url).includes("app_theme") ? Promise.resolve(new Response("", { status: 500 })) : fetch(url, options)
    JS

    find(".segmented__option", text: "Neutral").click

    expect(page).to have_content("Couldn't save that")
    expect(page).to have_css(".segmented__option:has(input:checked)", text: "Default (Classic)")
    expect(app_theme_attribute).to eq("classic")
    expect(user.reload.app_theme).to eq("default")
  end

  it "says a save failed in a toast when the page has moved on" do
    visit settings_root_path
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.fetch = (url, options) => String(url).includes("app_theme")
        ? new Promise(resolve => setTimeout(resolve, 1000)).then(() => new Response("", { status: 500 }))
        : fetch(url, options)
    JS

    find(".segmented__option", text: "Neutral").click
    click_link "Manage agent sessions"
    expect(page).to have_no_css(".settings-row")

    expect(page).to have_css("#coplan-toasts [role='alert']", text: "Couldn't save your theme")
    expect(app_theme_attribute).to eq("classic")
    expect(user.reload.app_theme).to eq("default")
  end

  it "treats a save redirected to sign-in as failed" do
    visit settings_root_path
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.fetch = (url, options) => String(url).includes("app_theme")
        ? Promise.resolve(Object.defineProperty(new Response("", { status: 200 }), "redirected", { value: true }))
        : fetch(url, options)
    JS

    find(".segmented__option", text: "Neutral").click

    expect(page).to have_content("Couldn't save that")
    expect(page).to have_css(".segmented__option:has(input:checked)", text: "Default (Classic)")
    expect(app_theme_attribute).to eq("classic")
    expect(page.evaluate_script("document.documentElement.dataset.appThemeChoice")).to eq("default")
  end

  it "sends each save with the session token from when it was picked" do
    visit settings_root_path
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.themeTokens = []
      window.fetch = (url, options) => {
        if (!String(url).includes("app_theme")) return fetch(url, options)
        const wait = options.body.includes("neutral") ? 400 : 0
        return new Promise(resolve => setTimeout(resolve, wait)).then(() => {
          window.themeTokens.push(options.headers["X-CSRF-Token"])
          return fetch(url, options)
        })
      }
    JS
    # Tests run without forgery protection, so give the page a token to send.
    page.execute_script("document.head.insertAdjacentHTML('beforeend', '<meta name=\"csrf-token\" content=\"first-session\">')")

    find(".segmented__option", text: "Neutral").click
    find(".segmented__option", exact_text: "Classic").click
    # As if the session changed while the Classic save waits in the queue.
    page.execute_script("document.querySelector('meta[name=\"csrf-token\"]').content = 'another-session'")

    Timeout.timeout(5) { sleep 0.1 until page.evaluate_script("window.themeTokens.length") == 2 }
    expect(page.evaluate_script("window.themeTokens")).to eq(%w[first-session first-session])
  end

  it "keeps quick picks in order and falls back to the last one that saved" do
    visit settings_root_path
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.fetch = (url, options) => {
        if (!String(url).includes("app_theme")) return fetch(url, options)
        if (options.body.includes("neutral")) return new Promise(resolve => setTimeout(resolve, 400)).then(() => fetch(url, options))
        return Promise.resolve(new Response("", { status: 500 }))
      }
    JS

    find(".segmented__option", text: "Neutral").click
    find(".segmented__option", exact_text: "Classic").click
    expect(app_theme_attribute).to eq("classic")

    expect(page).to have_content("Couldn't save that")
    expect(page).to have_css(".segmented__option:has(input:checked)", text: "Neutral")
    expect(app_theme_attribute).to eq("neutral")
    expect(user.reload.app_theme).to eq("neutral")
  end

  it "switches mode and theme from the bar's Appearance menu, in step with Settings" do
    visit settings_root_path
    find(".site-nav__appearance-btn").click
    expect(page).to have_css("#appearance-menu .appearance-menu__theme:has(input:checked)", text: "Classic")

    within("#appearance-menu") { find(".appearance-menu__theme", text: "Neutral").click }
    expect(app_theme_attribute).to eq("neutral")
    expect(page).to have_css(".settings-row .segmented__option:has(input:checked)", text: "Neutral")

    within("#appearance-menu") { find(".segmented__option", exact_text: "Dark").click }
    expect(page).to have_css("html[data-theme='dark']")
    expect(page).to have_css("#appearance-menu:popover-open")
    expect(page).to have_css("input[name='theme'][value='dark']:checked", visible: :all)
    Timeout.timeout(5) { sleep 0.1 until user.reload.app_theme == "neutral" && user.theme_preference == "dark" }

    find("body").send_keys(:escape)
    find(".settings-row .segmented__option", text: "Default (Classic)").click
    expect(app_theme_attribute).to eq("classic")
    expect(page).to have_css("input[name='appearance_theme'][value='classic']:checked", visible: :all)
    Timeout.timeout(5) { sleep 0.1 until user.reload.app_theme == "default" }
  end

  it "saves picks from Settings and the bar's menu in the order they were made" do
    visit settings_root_path
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.themeSaves = 0
      window.fetch = (url, options) => {
        if (!String(url).includes("app_theme")) return fetch(url, options)
        const wait = options.body.includes("neutral") ? 400 : 0
        return new Promise(resolve => setTimeout(resolve, wait)).then(() => fetch(url, options)).finally(() => window.themeSaves++)
      }
    JS

    find(".settings-row .segmented__option", text: "Neutral").click
    find(".site-nav__appearance-btn").click
    within("#appearance-menu") { find(".appearance-menu__theme", text: "Classic").click }
    expect(app_theme_attribute).to eq("classic")

    Timeout.timeout(5) { sleep 0.1 until page.evaluate_script("window.themeSaves") == 2 }
    expect(user.reload.app_theme).to eq("classic")
    expect(page).to have_no_content("Couldn't save that")
    # The older save landing last mustn't move either control off the newer pick.
    expect(page).to have_css("input[name='appearance_theme'][value='classic']:checked", visible: :all)
    expect(page).to have_css(".settings-row .segmented__option:has(input:checked)", exact_text: "Classic")
    expect(page.evaluate_script("document.documentElement.dataset.appThemeChoice")).to eq("classic")
  end

  it "puts both controls back on the last saved pick when a later pick in the other fails" do
    visit settings_root_path
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.fetch = (url, options) => {
        if (!String(url).includes("app_theme")) return fetch(url, options)
        if (options.body.includes("neutral")) return new Promise(resolve => setTimeout(resolve, 400)).then(() => fetch(url, options))
        return Promise.resolve(new Response("", { status: 500 }))
      }
    JS

    find(".settings-row .segmented__option", text: "Neutral").click
    find(".site-nav__appearance-btn").click
    within("#appearance-menu") { find(".appearance-menu__theme", text: "Classic").click }
    expect(app_theme_attribute).to eq("classic")

    expect(page).to have_content("Couldn't save that")
    expect(app_theme_attribute).to eq("neutral")
    expect(page).to have_css("input[name='appearance_theme'][value='neutral']:checked", visible: :all)
    expect(page).to have_css(".settings-row .segmented__option:has(input:checked)", text: "Neutral")
    expect(user.reload.app_theme).to eq("neutral")
  end

  it "shows a Default pick that's still saving on a Settings page Turbo renders" do
    user.update!(app_theme: "neutral")
    visit settings_root_path
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.fetch = (url, options) => String(url).includes("app_theme") ? new Promise(resolve => setTimeout(resolve, 4000)).then(() => fetch(url, options)) : fetch(url, options)
    JS

    find(".settings-row .segmented__option", text: "Default (Classic)").click
    click_link "Manage agent sessions"
    expect(page).to have_no_css(".settings-row")
    page.execute_script("Turbo.visit(#{settings_root_path.to_json})")

    expect(page).to have_css(".settings-row .segmented__option:has(input:checked)", text: "Default (Classic)", wait: 1)
    expect(user.reload.app_theme).to eq("neutral")
    Timeout.timeout(8) { sleep 0.1 until user.reload.app_theme == "default" }
    expect(page).to have_css(".settings-row .segmented__option:has(input:checked)", text: "Default (Classic)")
  end

  it "reads the stored choice from <html> once saves settle" do
    visit settings_root_path
    find(".segmented__option", text: "Neutral").click
    Timeout.timeout(5) { sleep 0.1 until page.evaluate_script("document.documentElement.dataset.appThemeChoice") == "neutral" }
    # As if another account's page now owns <html>.
    page.execute_script("const h = document.documentElement; h.dataset.appThemeChoice = 'default'; h.dataset.appTheme = 'classic'")

    click_link "Manage agent sessions"
    expect(page).to have_no_css(".settings-row")
    page.execute_script("Turbo.visit(#{settings_root_path.to_json})")

    expect(page).to have_css(".settings-row .segmented__option:has(input:checked)", text: "Default (Classic)")
  end

  it "saves mode picks from Settings and the bar's menu in the order they were made" do
    visit settings_root_path
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.modeSaves = 0
      window.fetch = (url, options) => {
        if (!String(url).includes("settings/theme")) return fetch(url, options)
        const wait = options.body.includes("dark") ? 400 : 0
        return new Promise(resolve => setTimeout(resolve, wait)).then(() => fetch(url, options)).finally(() => window.modeSaves++)
      }
    JS

    find(".settings-row .segmented__option", exact_text: "Dark").click
    find(".site-nav__appearance-btn").click
    within("#appearance-menu") { find(".segmented__option", exact_text: "Light").click }
    expect(page).to have_css("html[data-theme='light']")

    Timeout.timeout(5) { sleep 0.1 until page.evaluate_script("window.modeSaves") == 2 }
    expect(user.reload.theme_preference).to eq("light")
  end

  it "puts back the stored choice after a cache restore when a save fails" do
    visit settings_root_path
    click_link "Manage agent sessions"
    expect(page).to have_no_css(".settings-row")
    find(".site-nav__appearance-btn").click
    within("#appearance-menu") { find(".appearance-menu__theme", text: "Neutral").click }
    Timeout.timeout(5) { sleep 0.1 until user.reload.app_theme == "neutral" }
    find("body").send_keys(:escape)
    page.go_back
    expect(page).to have_css(".settings-row .segmented__option:has(input:checked)", text: "Neutral")

    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.fetch = (url, options) => String(url).includes("app_theme") ? Promise.resolve(new Response("", { status: 500 })) : fetch(url, options)
    JS
    find(".settings-row .segmented__option", text: "Default (Classic)").click

    expect(page).to have_content("Couldn't save that")
    expect(page).to have_css(".settings-row .segmented__option:has(input:checked)", text: "Neutral")
    expect(app_theme_attribute).to eq("neutral")
    expect(user.reload.app_theme).to eq("neutral")
  end

  it "keeps the Appearance menu on screen on the narrowest phones" do
    # Headless Chrome keeps windows wider than this, so emulate the screen.
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 700, deviceScaleFactor: 1, mobile: true)
    visit settings_root_path
    find(".site-nav__appearance-btn").click
    expect(page).to have_css("#appearance-menu:popover-open")
    left, right = page.evaluate_script("(r => [r.left, r.right])(document.getElementById('appearance-menu').getBoundingClientRect())")
    expect(left).to be >= 0
    expect(right).to be <= 320
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "shows the current pick in a menu Turbo restores from its cache" do
    visit settings_root_path
    find(".site-nav__appearance-btn").click
    within("#appearance-menu") { find(".appearance-menu__theme", text: "Neutral").click }
    Timeout.timeout(5) { sleep 0.1 until user.reload.app_theme == "neutral" }
    find("body").send_keys(:escape)

    click_link "Manage agent sessions"
    expect(page).to have_no_css(".settings-row")
    find(".site-nav__appearance-btn").click
    within("#appearance-menu") { find(".appearance-menu__theme", text: "Classic").click }
    Timeout.timeout(5) { sleep 0.1 until user.reload.app_theme == "classic" }
    page.go_back

    expect(page).to have_css(".settings-row .segmented__option:has(input:checked)", text: "Classic")
    expect(page).to have_css("input[name='appearance_theme'][value='classic']:checked", visible: :all)
  end

  describe "Neutral" do
    before { user.update!(app_theme: "neutral") }

    it "sets the document flat on the page with the reading type, in both modes" do
      visit plan_page_path(plan)
      expect(page).to have_css(".plan-reader .markdown-rendered pre[lang='ruby']")

      %w[light dark].each do |mode|
        page.execute_script("document.documentElement.dataset.theme = '#{mode}'")

        expect(style(".plan-document", "box-shadow")).to eq("none")
        expect(style(".plan-document", "border-top-width")).to eq("0px")
        expect(style(".plan-document", "background-color")).to eq(style("body", "background-color"))
        expect(style("body", "background-image")).to eq("none")
        expect(style(".site-nav", "backdrop-filter")).to eq("none")
        expect(style(".plan-reader .markdown-rendered p", "line-height")).to eq("25.6px")
        expect(style(".plan-reader .markdown-rendered", "font-family")).to start_with("system-ui")
        expect(style(".plan-reader .markdown-rendered h2", "font-weight")).to eq("500")
        expect(style(".plan-reader .markdown-rendered strong", "font-weight")).to eq("600")
        expect(style(".plan-title__heading", "font-size")).to eq("28px")
        expect(%w[h1 h2 h3].map { |h| style(".plan-reader .markdown-rendered #{h}", "font-size") }).to eq(%w[24px 20px 18px])
        expect(style(".plan-reader .markdown-rendered pre", "border-top-width")).to eq("0px")
        expect(style(".plan-reader .markdown-rendered pre[lang]", "text-align", "::before")).to eq("right")
        expect(style(".plan-reader .markdown-rendered pre[lang]", "background-image", "::before")).to eq("none")
      end
    end

    it "sets editor paragraphs like the reader's" do
      visit plan_page_path(plan)
      reader = %w[font-family font-size line-height margin-bottom].index_with { |property| style(".plan-reader .markdown-rendered p", property) }

      visit plan_edit_page_path(plan)
      expect(page).to have_css(".document-editor__body .markdown-rendered p", wait: 10)
      editor = reader.keys.index_with { |property| style(".document-editor__body .markdown-rendered p", property) }

      expect(editor).to eq(reader)
    end

    it "keeps deck diagrams in the deck's font and colors while document diagrams follow the theme" do
      plan.current_plan_version.update_columns(content_markdown: <<~MD)
        ```mermaid
        flowchart LR
          Request --> Outbox
        ```

        ::: {.presentation}

        # Slide

        ```mermaid
        flowchart LR
          Deck --> Slide
        ```

        :::
      MD
      visit plan_page_path(plan)
      expect(page).to have_css(".mermaid-diagram .nodeLabel", count: 4, wait: 30)

      fonts = page.evaluate_script(<<~JS)
        Object.fromEntries([...document.querySelectorAll(".mermaid-diagram .nodeLabel")].map(label =>
          [label.closest(".deck") ? "deck" : "document", getComputedStyle(label).fontFamily]))
      JS
      document_font, deck_font = fonts.values_at("document", "deck")
      expect(document_font).to start_with("system-ui")
      expect(deck_font).to start_with("Lexend")

      themes = page.evaluate_script(<<~JS)
        Object.fromEntries([...document.querySelectorAll(".mermaid-diagram")].map(diagram =>
          [diagram.closest(".deck") ? "deck" : "document", diagram.dataset.mermaidTheme]))
      JS
      expect(themes["document"]).to start_with("neutral-")
      expect(themes["deck"]).to eq("light")
    end
  end
end
