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
        expect(style(".page-header__title", "font-size")).to eq("28px")
        expect(style(".plan-reader .markdown-rendered pre", "border-top-width")).to eq("0px")
        expect(style(".plan-reader .markdown-rendered pre[lang]", "text-align", "::before")).to eq("right")
        expect(style(".plan-reader .markdown-rendered pre[lang]", "background-image", "::before")).to eq("none")
      end
    end

    it "hides an opening H1 that repeats the plan title, but only in Neutral" do
      visit plan_page_path(plan)
      h1 = ".plan-reader .markdown-rendered--repeats-title > h1"
      expect(page).to have_css(h1, text: "Durable outbox", visible: :all)
      expect(style(h1, "position")).to eq("absolute")
      expect(style(h1, "clip-path")).to eq("inset(50%)")

      user.update!(app_theme: "classic")
      visit plan_page_path(plan)
      expect(page).to have_css(h1, text: "Durable outbox")
      expect(style(h1, "position")).to eq("static")
    end

    it "sets editor paragraphs like the reader's" do
      visit plan_page_path(plan)
      reader = %w[font-family font-size line-height margin-bottom].index_with { |property| style(".plan-reader .markdown-rendered p", property) }

      visit plan_edit_page_path(plan)
      expect(page).to have_css(".document-editor__body .markdown-rendered p", wait: 10)
      editor = reader.keys.index_with { |property| style(".document-editor__body .markdown-rendered p", property) }

      expect(editor).to eq(reader)
    end

    it "keeps deck diagrams in the deck's font while document diagrams follow the theme" do
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
    end
  end
end
