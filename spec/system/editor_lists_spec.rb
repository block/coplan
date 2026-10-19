require "rails_helper"

RSpec.describe "Editor lists", type: :system do
  let(:author) { create(:coplan_user, email: "lists@example.com") }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:modifier) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path, wait: 20)
    expect(page).to have_button("Menu", wait: 20)
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
        return { depth: $head.depth, parent: $head.parent.type.name, text: $head.parent.textContent, offset: $head.parentOffset,
          left: view.coordsAtPos($head.pos).left, top: view.coordsAtPos($head.pos).top }
      })()
    JS
  end

  def place_at_paragraph_end(selector, text, depth: 1)
    find(selector).click
    expect(page).to have_css(selector, text:, exact_text: true) {
      caret.values_at("depth", "text") == [ depth, text ]
    }
    page.driver.browser.action.send_keys(:end).perform
    expect(page).to have_css(selector, text:, exact_text: true) { caret["offset"] == text.length }
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

  [ [ "1)", nil ], [ "1.", nil ], [ "A)", "A" ], [ "a)", "a" ], [ "Z)", "A" ] ].each do |marker, type|
    it "creates a list with #{marker} and Space, restores its marker, and saves its style" do
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", type == "a" ? "dark" : "light")
      replace_body(marker)
      editor.send_keys(:space)
      expect(page).to have_css(".ProseMirror > ol > li", count: 1)
      expect(editor.find("ol")["type"].presence).to eq(type)
      editor.send_keys(:backspace)
      expect(page).to have_no_css(".ProseMirror ol")
      expect(editor.find("p").text).to eq("#{marker} ")
      replace_body(marker)
      editor.send_keys(:space, "One", :enter, "Two", :enter)
      expect(page).to have_css(".ProseMirror ol > li", count: 3)
      editor.send_keys(:backspace)
      expect(page).to have_css(".ProseMirror > p", count: 1)
      expect(caret).to include("depth" => 1)
      editor.send_keys(:backspace, " continued")
      expect(page).to have_css(".ProseMirror > ol > li", count: 2)
      expect(page).to have_no_css(".ProseMirror > p")
      expect(editor.find("li:last-child").text).to eq("Two continued")
      style = type == "A" ? "upper-alpha" : type == "a" ? "lower-alpha" : "decimal"
      expect(page.evaluate_script('getComputedStyle(document.querySelector(".ProseMirror > ol")).listStyleType')).to eq(style)
      snapshot = type ? "#{type == 'A' ? 'upper' : 'lower'}-#{marker[0].downcase}" : "number"
      page.save_screenshot(Rails.root.join("tmp/editor-ordered-shortcut-#{snapshot}.png"))
      editor.send_keys([ modifier, "s" ])
      expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: /All changes saved/, visible: :all, wait: 15)
      expect(plan.reload.current_content).to include(type ? "#{marker} One" : "1. One")
      expect(plan.current_content).to include("AA) Two continued") if marker == "Z)"
      visit plan_page_path(plan)
      expect(page).to have_css("#plan-content-body ol > li", count: 2, wait: 20)
      expect(find("#plan-content-body ol")["type"].presence).to eq(type)
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".ProseMirror > ol > li", count: 2, wait: 20)
      expect(editor.find("ol")["type"].presence).to eq(type)
    end
  end

  [ [ "1)", "A)", [ nil, "A" ] ], [ "A)", "a)", [ "A", "a" ] ] ].each do |first, second, types|
    it "keeps #{first} and #{second} in separate lists after saving" do
      replace_body(first)
      editor.send_keys(:space, "First", :enter, :enter, second, :space, "Second")
      expect(page).to have_css(".ProseMirror > ol", count: 2)
      expect(editor.all("ol").map { |list| list["type"].presence }).to eq(types)
      editor.send_keys([ modifier, "s" ])
      expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: /All changes saved/, visible: :all, wait: 15)
      visit plan_page_path(plan)
      expect(page).to have_css("#plan-content-body ol", count: 2, wait: 20)
      expect(all("#plan-content-body ol").map { |list| list["type"].presence }).to eq(types)
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".ProseMirror > ol", count: 2, wait: 20)
      expect(editor.all("ol").map { |list| list["type"].presence }).to eq(types)
    end
  end

  [ "Bullet list", "Numbered list" ].each do |button|
    it "exits an empty final item created with the #{button} toolbar command" do
      replace_body("First item")
      click_button button, exact: true, enable_aria_label: true
      editor.send_keys(:enter)
      expect(page).to have_css(".ProseMirror li", count: 2)
      editor.send_keys(:backspace)
      expect(page).to have_css(".ProseMirror li", count: 1)
      expect(caret).to include("depth" => 1)
      editor.send_keys(:backspace, " continued")
      expect(page).to have_css(".ProseMirror li", count: 1)
      expect(page).to have_css(".ProseMirror li", text: "First item continued")
      expect(page).to have_no_css(".ProseMirror > p")
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
    it "returns to the previous item's content on the second Backspace without creating another bullet in #{theme}" do
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      replace_body("*")
      editor.send_keys(:space, "hi", :enter, "hello", :enter)
      expect(page).to have_css(".ProseMirror li", count: 3)
      editor.send_keys(:backspace)
      expect(page).to have_css(".ProseMirror li", count: 2)
      expect(caret).to include("depth" => 1, "parent" => "paragraph")
      editor.send_keys(:backspace)
      expect(page).to have_css(".ProseMirror li", count: 2)
      expect(page).to have_no_css(".ProseMirror > p")
      expect(caret).to include("depth" => 3, "parent" => "paragraph")
      editor.send_keys(" again")
      expect(page).to have_css(".ProseMirror li:last-child", text: "hello again")
      page.save_screenshot(Rails.root.join("tmp/editor-list-boundary-#{theme}.png"))
      editor.send_keys([ modifier, "s" ])
      expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: /All changes saved/, visible: :all, wait: 15)
      expect(plan.reload.current_content.scan(/^\* /).length).to eq(2)
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".ProseMirror li", count: 2, wait: 20)
      expect(page).to have_no_css(".ProseMirror > p")
    end
  end

  it "exits an empty bullet with Enter without leaving empty items or extra paragraphs" do
    replace_body("*")
    editor.send_keys(:space, "hi", :enter, "hello", :enter, :enter)
    expect(page).to have_css(".ProseMirror li", count: 2)
    expect(page).to have_css(".ProseMirror > p", count: 1)
    expect(caret).to include("depth" => 1, "parent" => "paragraph")
    editor.send_keys(:backspace)
    expect(page).to have_css(".ProseMirror li", count: 2)
    expect(page).to have_no_css(".ProseMirror > p")
    editor.send_keys(" again")
    expect(page).to have_css(".ProseMirror li:last-child", text: "hello again")
  end

  it "deletes successive empty lines below a list without adding bullets" do
    replace_body("*")
    editor.send_keys(:space, "hi", :enter, "hello", :enter, :backspace, :enter, :enter)
    expect(page).to have_css(".ProseMirror li", count: 2)
    expect(page).to have_css(".ProseMirror > p", count: 3)
    3.times do |index|
      editor.send_keys(:backspace)
      expect(page).to have_css(".ProseMirror li", count: 2)
      expect(page).to have_css(".ProseMirror > p", count: 2 - index)
    end
    editor.send_keys(" again")
    expect(page).to have_css(".ProseMirror li:last-child", text: "hello again")
  end

  it "keeps a non-empty paragraph separate when Backspace brings it into the list" do
    replace_body("*")
    editor.send_keys(:space, "One", :enter, :enter, "Outside")
    7.times { page.driver.browser.action.send_keys(:arrow_left).perform }
    # The browser's selectionchange reaches the editor after the key event.
    expect(page).to have_css(".ProseMirror > p", text: "Outside", exact_text: true) {
      caret.values_at("depth", "offset") == [ 1, 0 ]
    }
    page.driver.browser.action.send_keys(:backspace).perform
    expect(page).to have_css(".ProseMirror li", count: 2)
    expect(editor.find("li:first-child").text).to eq("One")
    expect(editor.find("li:last-child").text).to eq("Outside")
  end

  [ [ "-", "ul", "light" ], [ "1.", "ol", "dark" ] ].each do |marker, tag, theme|
    it "does not recreate an empty #{tag} item after an item ending in a preserved table in #{theme}" do
      indentation = " " * (marker.length + 1)
      source = "#{marker} Item with table\n\n#{indentation}| Name | State |\n#{indentation}| --- | --- |\n#{indentation}| Alpha | Ready |\n\n#{marker} \n"
      CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
        base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
      visit plan_edit_page_path(plan)
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      expect(page).to have_css(".ProseMirror > #{tag} > li", count: 2, wait: 20)
      expect(page).to have_css(".ProseMirror li table td", text: "Ready")
      find(".ProseMirror > #{tag} > li:last-child > p").click
      expect(page).to have_css(".ProseMirror > #{tag} > li:last-child > p") {
        caret.values_at("depth", "text") == [ 3, "" ]
      }
      page.driver.browser.action.send_keys(:backspace).perform
      expect(page).to have_css(".ProseMirror > #{tag} > li", count: 1)
      expect(page).to have_css(".ProseMirror > p", count: 1)
      page.driver.browser.action.send_keys(:backspace).perform
      expect(page).to have_css(".ProseMirror > #{tag} > li", count: 1)
      expect(page).to have_no_css(".ProseMirror > p")
      expect(caret).to include("depth" => 3, "offset" => "Item with table".length)
      page.driver.browser.action.send_keys(" continued").perform
      expect(page).to have_css(".ProseMirror li > p", text: "Item with table continued", exact_text: true)
      expect(page).to have_css(".ProseMirror li table td", text: "Ready")
      page.save_screenshot(Rails.root.join("tmp/editor-table-boundary-#{theme}.png"))
      editor.send_keys([ modifier, "s" ])
      expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: /All changes saved/, visible: :all, wait: 15)
      expect(plan.reload.current_content).to include("Item with table continued", "| Alpha | Ready |")
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".ProseMirror > #{tag} > li", count: 1, wait: 20)
      expect(page).to have_css(".ProseMirror li table td", text: "Ready")
    end
  end

  it "keeps citation metadata intact when editing and leaving a list at the document's end" do
    cited = CoPlan::Plans::Create.call(title: "List after citation", content: "Opening.[^note]\n\n[^note]: Keep this reference.\n",
      user: author, visibility: "draft", actor_type: "human")
    visit plan_edit_page_path(cited)
    expect(page).to have_css(".ProseMirror > p:last-child", wait: 20)
    find(".ProseMirror > p:last-child").click
    page.driver.browser.action.send_keys("*", :space, "hi", :enter, "hello", :enter).perform
    expect(page).to have_css(".ProseMirror li", count: 3)
    page.driver.browser.action.send_keys(:backspace).perform
    expect(page).to have_css(".ProseMirror li", count: 2)
    expect(page).to have_css(".ProseMirror > p", count: 2)
    page.driver.browser.action.send_keys(:backspace).perform
    expect(page).to have_css(".ProseMirror li", count: 2)
    expect(page).to have_css(".ProseMirror > p", count: 1)
    expect(caret).to include("depth" => 3)
    page.driver.browser.action.send_keys(" again").perform
    expect(page).to have_css(".ProseMirror li:last-child", text: "hello again")
    editor.send_keys([ modifier, "s" ])
    expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: /All changes saved/, visible: :all, wait: 15)
    expect(cited.reload.current_content).to include("[^note]: Keep this reference.", "hello again")
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

  it "keeps multiple lettered markers literal inside an HTML block" do
    source = "<div>\nA) First literal\nB) Second literal\n</div>\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".ProseMirror .document-editor__block-preview", text: "A) First literal", wait: 20)
    expect(page).to have_no_css(".ProseMirror ol")
    expect(editor.text).to include("B) Second literal")
  end

  it "preserves lettered task lists when editing nearby text" do
    source = "A) [ ] Keep this task\n\nOutside\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    expect(page).to have_css('.ProseMirror .document-editor__block-preview input[type="checkbox"]', wait: 20)
    place_at_paragraph_end(".ProseMirror > p", "Outside")
    page.driver.browser.action.send_keys(" continued").perform
    editor.send_keys([ modifier, "s" ])
    expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: /All changes saved/, visible: :all, wait: 15)
    expect(plan.reload.current_content).to include("A) [ ] Keep this task", "Outside continued")
  end

  it "keeps letter-like markers literal inside a nested pipe-less table after saving" do
    source = "AA) Parent\n\n    A) Name | State\n    --- | ---\n    B) Label | Ready\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".ProseMirror > ol > li", count: 1, wait: 20)
    expect(page).to have_css(".ProseMirror li table th", text: "A) Name")
    expect(page).to have_css(".ProseMirror li table td", text: "B) Label")
    place_at_paragraph_end(".ProseMirror > ol > li > p", "Parent", depth: 3)
    page.driver.browser.action.send_keys(" continued").perform
    expect(page).to have_css(".ProseMirror > ol > li > p", text: "Parent continued", exact_text: true)
    editor.send_keys([ modifier, "s" ])
    expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: /All changes saved/, visible: :all, wait: 15)
    expect(plan.reload.current_content).to include("A) Name | State", "B) Label | Ready")
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-content-body li table td", text: "B) Label", wait: 20)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".ProseMirror li table th", text: "A) Name", wait: 20)
  end

  it "does not convert list markers inside prose or code" do
    [ "*", "1)", "A)" ].each do |marker|
      replace_body("Literal #{marker} ")
      expect(page).to have_no_css(".ProseMirror ul, .ProseMirror ol")
    end
    replace_body("code placeholder")
    select "Code block", from: "Paragraph style", enable_aria_label: true
    expect(page).to have_css(".ProseMirror pre")
    find(".ProseMirror pre > code").click
    page.driver.browser.action.key_down(modifier).send_keys("a").key_up(modifier).perform
    expect(caret).to include("parent" => "code_block")
    page.driver.browser.action.send_keys("*", :space, :enter, "1)", :space, :enter, "A)", :space).perform
    expect(page).to have_css(".ProseMirror pre", text: "1)")
    expect(page).to have_css(".ProseMirror pre", text: "A)")
    expect(page).to have_no_css(".ProseMirror ul, .ProseMirror ol")
  end
end
