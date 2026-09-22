require "rails_helper"
RSpec.describe "Editor code caret", type: :system do
  let(:author) { create(:coplan_user, email: "caret@example.com") }
  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end
  def caret
    page.evaluate_script(<<~'JS')
      (() => { const c = Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor"), v=c.richEditor.view, s=getSelection();
      return { model:v.state.selection.toJSON(), parent:v.state.selection.$head.parent.type.name, rect:v.coordsAtPos(v.state.selection.head), dom:s.anchorNode?.nodeName, offset:s.anchorOffset, pre:document.querySelector(".document-editor__block > pre").getBoundingClientRect().toJSON(), text:document.querySelector(".document-editor__block > pre").textContent }; })()
    JS
  end
  it "advances the visible caret for each Enter in a newly inserted javascript block" do
    visit new_plan_path
    expect(page).to have_css('.ProseMirror[contenteditable=true]', wait: 20)
    fill_in "plan_title", with: "Caret regression"
    click_button "Insert code block"
    fill_in "coplan-insert-language", with: "javascript"
    click_button "Insert", exact: true
    find('.document-editor__block > pre').click
    page.driver.browser.action.send_keys("function hi() {").perform
    prior = caret
    3.times do
      page.driver.browser.action.send_keys(:enter).perform
      current = caret
      expect(current["parent"]).to eq("code_block")
      expect(current["rect"]["top"]).to be >= prior["rect"]["top"] + 15
      prior = current
    end
    page.save_screenshot(Rails.root.join("tmp/editor-code-enter.png"))
    page.driver.browser.action.send_keys(:tab, "return 1", :enter).perform
    expect(caret["text"]).to include("  return 1\n  ")
    prior = caret
    page.driver.browser.action.send_keys(:arrow_up).perform
    Selenium::WebDriver::Wait.new(timeout: 3).until { caret["rect"]["top"] < prior["rect"]["top"] }
    page.driver.browser.action.send_keys(:arrow_down, :backspace, :delete).perform
    expect(page).to have_content("All changes saved", wait: 10)
    click_button "Dual", exact: true
    expect(find('[aria-label="Markdown source"]')).to have_text("```javascript")
    find('[aria-label="Code language"]').fill_in(with: "typescript")
    code = find('.document-editor__block > pre')
    code.click
    page.driver.browser.action.key_down(:meta).send_keys(:arrow_down).key_up(:meta).perform
    # Select the end of the code text using the DOM to isolate navigation from insertion.
    page.execute_script(<<~'JS')
      const code = document.querySelector(".document-editor__block > pre > code"), selection = getSelection(), range = document.createRange();
      range.selectNodeContents(code); range.collapse(false); selection.removeAllRanges(); selection.addRange(range);
    JS
    prior = caret
    page.driver.browser.action.send_keys(:enter).perform
    expect(caret["rect"]["top"]).to be > prior["rect"]["top"]
    click_link "Back"
    created = CoPlan::Plan.find_by!(title: "Caret regression")
    expect(page).to have_current_path(plan_page_path(created), wait: 10)
    expect(created.reload.current_content).to include("```typescript", "function hi() {", "return 1")
  end
end
