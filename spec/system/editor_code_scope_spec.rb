require "rails_helper"

RSpec.describe "Editable code selection and highlighting", type: :system do
  let(:author) { create(:coplan_user, email: "code-scope@example.com") }
  let(:source) { "Before prose.\n\n```js extra=1\nfunction hi() {\n  return 42;\n}\n```\n\nAfter prose.\n\n```ruby\nputs :other\n```\n" }
  let(:plan) { CoPlan::Plans::Create.call(title: "Code scopes", content: source, user: author, visibility: "draft", actor_type: "human") }
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css('[aria-label="Document body"]', wait: 20)
  end

  def code
    all(".document-editor__block > pre > code").first
  end

  it "moves ArrowDown into existing prose after code without inserting a paragraph" do
    [ "Editor", "Dual" ].each do |mode|
      click_button mode, exact: true
      paragraphs = all('[aria-label="Document body"] p').count
      code.click
      page.driver.browser.action.key_down(mod).send_keys("a").key_up(mod).send_keys(:arrow_right).perform
      Selenium::WebDriver::Wait.new(timeout: 3).until do
        page.evaluate_script('(() => { const s = Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor").richEditor.view.state.selection; return s.empty && s.$head.parent.type.name === "code_block" && s.$head.parentOffset === s.$head.parent.content.size })()')
      end
      page.driver.browser.action.send_keys(:arrow_down).perform
      expect(all('[aria-label="Document body"] p').count).to eq(paragraphs)
      expect(page.evaluate_script('getSelection().anchorNode.parentElement.closest("p")?.textContent')).to eq("After prose.")
      expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(source)
    end
    page.driver.browser.action.send_keys("Reached ").perform
    expect(find('[aria-label="Document body"] p', text: "Reached After prose.")).to be_present
    click_link "Close editor"
    expect(page).to have_current_path(plan_page_path(plan), wait: 10)
    expect(plan.reload.current_content).to eq(source.sub("After prose.", "Reached After prose."))
  end

  it "selects and replaces only focused code in Rich and Dual, retaining other blocks and native inputs" do
    [ "Editor", "Dual" ].each do |mode|
      click_button mode, exact: true
      code.click
      page.driver.browser.action.key_down(mod).send_keys("a").key_up(mod).perform
      expect(page.evaluate_script("getSelection().toString()")).to eq(code.text)
      expect(page.evaluate_script('getSelection().toString()')).not_to include("Before prose", "Language", "After prose", "puts :other")
      page.driver.browser.action.send_keys("const scoped = 7;").perform
      expect(code).to have_text("const scoped = 7;")
      expect(find('[aria-label="Document body"]')).to have_text("Before prose.")
      expect(find('[aria-label="Document body"]')).to have_text("After prose.")
      expect(all(".document-editor__block > pre > code").last).to have_text("puts :other")
      language = all('[aria-label="Code language"]').first
      language.send_keys([ mod, "a" ], "typescript")
      expect(language.value).to eq("typescript")
      expect(code).to have_text("const scoped = 7;")
    end
    raw = find('[aria-label="Markdown source"]')
    raw.click
    raw.send_keys([ mod, "a" ])
    expect(page.evaluate_script('getSelection().toString()')).to include("Before prose.", "After prose.", "```typescript")
    find('[aria-label="Document body"] p', text: "Before prose.").click
    page.driver.browser.action.key_down(mod).send_keys("a").key_up(mod).perform
    expect(page.evaluate_script('getSelection().toString()')).to include("Before prose.", "After prose.")
    expect(page.evaluate_script('getSelection().toString()')).not_to include("Code scopes", "Editor", "Dual")
    find("#plan_title").send_keys([ mod, "a" ], "Scoped title")
    click_link "Close editor"
    expect(page).to have_current_path(/scoped-title$/, wait: 10)
    expect(plan.reload.current_content).to include("Before prose.", "const scoped = 7;", "After prose.", "puts :other")
  end

  it "decorates editable code without changing source, updates aliases/languages and retains themed tokens" do
    expect(code).to have_css(".hljs-keyword", text: "function", wait: 20)
    expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(source)
    expect(page).not_to have_content("Changes save automatically")
    click_button "Dual", exact: true
    expect(code).to have_css(".hljs-number", text: "42")
    %w[light dark].each do |theme|
      page.execute_script('document.documentElement.dataset.theme = arguments[0]', theme)
      colors = page.evaluate_script('(() => { const c = document.querySelector(".document-editor__block code"), t = c.querySelector(".hljs-keyword"); return [getComputedStyle(c).color,getComputedStyle(t).color] })()')
      expect(colors[0]).not_to eq(colors[1])
    end
    language = all('[aria-label="Code language"]').first
    language.send_keys([ mod, "a" ], "unknown-language extra=1")
    expect(code).not_to have_css("[class^=hljs-]", wait: 10)
    language.send_keys([ mod, "a" ], "javascript metadata")
    expect(code).to have_css(".hljs-keyword", text: "function", wait: 10)
    code.click
    page.driver.browser.action.key_down(mod).send_keys("a").key_up(mod).send_keys('const greeting = "hello";').perform
    expect(code).to have_css(".hljs-string", text: '"hello"')
    page.driver.browser.action.key_down(mod).send_keys("z").key_up(mod).perform
    expect(code).to have_text("function hi()")
    expect(code).to have_css(".hljs-number", text: "42")
    page.save_screenshot(Rails.root.join("tmp/editor-highlighted-code.png"))
    click_link "Close editor"
    expect(page).to have_current_path(plan_page_path(plan), wait: 10)
    expect(plan.reload.current_content).to include("return 42;")
    expect(page).to have_css(".hljs-keyword", text: "function", wait: 20)
  end

  it "falls back to plain text for large blocks without rewriting their source" do
    large = "```javascript\n" + ("const number = 42;\n" * 1200) + "```\n"
    large_plan = CoPlan::Plans::Create.call(title: "Large code", content: large, user: author, visibility: "draft", actor_type: "human")
    visit plan_edit_page_path(large_plan)
    expect(page).to have_css('[aria-label="Document body"]', wait: 20)
    expect(code).to have_text("const number = 42;")
    expect(code).not_to have_css("[class^=hljs-]")
    expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(large)
  end

  it "keeps macOS Control+A as line navigation within code" do
    skip "macOS native shortcut" unless RUBY_PLATFORM.include?("darwin")
    expect(code).to have_css(".hljs-keyword", wait: 20)
    code.click
    page.driver.browser.action.key_down(:meta).send_keys("a").key_up(:meta).send_keys(:arrow_left, :arrow_down, :arrow_right).perform
    page.driver.browser.action.key_down(:control).send_keys("a").key_up(:control).perform
    expect(page.evaluate_script('getSelection().toString()')).to eq("")
    prefix = page.evaluate_script(<<~'JS')
      (() => {
        const s = getSelection(), range = document.createRange();
        range.setStart(document.querySelector(".document-editor__block > pre > code"), 0);
        range.setEnd(s.anchorNode, s.anchorOffset);
        return range.toString();
      })()
    JS
    expect(prefix).to eq("function hi() {\n")
  end
end
