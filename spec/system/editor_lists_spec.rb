require "rails_helper"

RSpec.describe "Editor lists", type: :system do
  let(:author) { create(:coplan_user, email: "lists@example.com") }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:modifier) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")
    visit plan_edit_page_path(plan)
    expect(page).to have_css('.ProseMirror[contenteditable="true"]', wait: 20)
  end

  def editor
    find('.ProseMirror[contenteditable="true"]')
  end

  def replace_body(text)
    editor.send_keys([ modifier, "a" ], text)
  end

  def caret
    page.evaluate_script(<<~'JS')
      (() => {
        const form = document.querySelector("form.document-editor")
        const view = Stimulus.getControllerForElementAndIdentifier(form, "coplan--editor").richEditor.view
        const { $head } = view.state.selection
        return { depth: $head.depth, parent: $head.parent.type.name,
          left: view.coordsAtPos($head.pos).left, top: view.coordsAtPos($head.pos).top }
      })()
    JS
  end

  it "turns a leading asterisk and space into a bullet and immediately restores the literal marker with Backspace" do
    replace_body("*")
    expect(page).to have_no_css(".ProseMirror ul")
    editor.send_keys(:space)
    expect(page).to have_css(".ProseMirror > ul > li > p", count: 1)
    editor.send_keys(:backspace)
    expect(page).to have_no_css(".ProseMirror ul")
    expect(editor.find("p").text).to eq("* ")
    expect(caret).to include("depth" => 1, "parent" => "paragraph")
    editor.send_keys("literal text")
    expect(editor.find("p").text).to eq("* literal text")
  end

  [ "Bullet list", "Numbered list" ].each do |button|
    it "exits an empty final item created with the #{button} toolbar command" do
      replace_body("First item")
      click_button button, exact: true, enable_aria_label: true
      editor.send_keys(:enter)
      expect(page).to have_css(".ProseMirror li", count: 2)
      editor.send_keys(:backspace, "Outside the list")
      expect(page).to have_css(".ProseMirror li", count: 1)
      expect(page).to have_css(".ProseMirror > p", text: "Outside the list")
      expect(caret).to include("depth" => 1)
    end
  end

  it "lifts an empty nested item one level at a time" do
    replace_body("*")
    editor.send_keys(:space, "Parent", :enter, "Child", :tab, :enter)
    expect(page).to have_css(".ProseMirror > ul > li > ul > li", count: 2)
    editor.send_keys(:backspace)
    expect(page).to have_css(".ProseMirror > ul > li > ul > li", count: 1)
    expect(caret).to include("depth" => 3)
    editor.send_keys(:backspace, "Outside")
    expect(page).to have_css(".ProseMirror > p", text: "Outside")
    expect(caret).to include("depth" => 1)
  end

  %w[light dark].each do |theme|
    it "leaves a blank final bullet flush with prose after Backspace in #{theme}" do
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      replace_body("Opening paragraph.")
      paragraph_left = editor.find("p").rect.x
      editor.send_keys(:enter, "*", :space, "First bullet", :enter)
      expect(page).to have_css(".ProseMirror > ul > li", count: 2)
      bullet_caret = caret
      editor.send_keys(:backspace)
      expect(page).to have_css(".ProseMirror > ul > li", count: 1)
      expect(page).to have_css(".ProseMirror > p", count: 2)
      expect(caret).to include("depth" => 1, "parent" => "paragraph")
      expect(caret.fetch("left")).to be_within(1).of(paragraph_left)
      expect(caret.fetch("top")).to be >= bullet_caret.fetch("top")
      editor.send_keys("Back to prose.")
      expect(page).to have_css(".ProseMirror > p", text: "Back to prose.")
      page.save_screenshot(Rails.root.join("tmp/editor-lists-#{theme}.png"))
      editor.send_keys([ modifier, "s" ])
      expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: /All changes saved/, visible: :all, wait: 15)
      expect(plan.reload.current_content).to match(/First bullet\n\nBack to prose\./)
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".ProseMirror > ul > li", text: "First bullet", wait: 20)
      expect(page).to have_css(".ProseMirror > p", text: "Back to prose.")
    end
  end

  it "does not convert an asterisk inside prose or code" do
    replace_body("Literal * ")
    expect(page).to have_no_css(".ProseMirror ul")
    replace_body("code placeholder")
    select "Code block", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".ProseMirror pre")
    find(".ProseMirror pre > code").click
    page.driver.browser.action.key_down(modifier).send_keys("a").key_up(modifier).perform
    expect(caret).to include("parent" => "code_block")
    page.driver.browser.action.send_keys("*", :space).perform
    expect(page).to have_css(".ProseMirror pre", text: "*")
    expect(page).to have_no_css(".ProseMirror ul")
  end
end
