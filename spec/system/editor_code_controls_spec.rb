require "rails_helper"

RSpec.describe "Editor code controls", type: :system do
  let(:author) { create(:coplan_user, email: "code-controls@example.com") }
  let(:source) { "Before prose.\n\nAfter prose.\n" }
  let(:plan) { CoPlan::Plans::Create.call(title: "Code controls", content: source, user: author, visibility: "draft", actor_type: "human") }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css('[aria-label="Document body"]', wait: 20)
    find('[aria-label="Document body"] p', text: "After prose.").click
  end

  it "anchors its searchable picker to the toolbar and inserts the chosen JavaScript language" do
    click_button "Insert code block"
    expect(page).to have_css("#coplan-insert-language:focus")
    bounds = page.evaluate_script('(() => { const button = document.querySelector("[popovertarget=coplan-insert-code]").getBoundingClientRect(); const picker = document.querySelector("#coplan-insert-code").getBoundingClientRect(); return { gap: picker.top - button.bottom, offset: picker.left - button.left } })()')
    expect(bounds["gap"]).to be_between(0, 10)
    expect(bounds["offset"].abs).to be < 2
    fill_in "coplan-insert-language", with: "java"
    expect(page).to have_css('[role="option"]', text: "JavaScript")
    expect(page).not_to have_css('[role="option"]', text: "Ruby")
    page.save_screenshot(Rails.root.join("tmp/editor-code-picker.png"))
    find('[role="option"]', text: "JavaScript", exact_text: true).click
    expect(page).not_to have_css("#coplan-insert-code:popover-open")
    expect(find('[aria-label="Code language"]').value).to eq("javascript")
    expect(page.evaluate_script('(() => { const node = getSelection().anchorNode; return (node.nodeType === 1 ? node : node.parentElement).closest("code") !== null })()')).to eq(true)
    page.driver.browser.action.send_keys("const answer = 42;").perform
    expect(page).to have_css(".document-editor__block code .hljs-keyword", text: "const", wait: 10)
    page.save_screenshot(Rails.root.join("tmp/editor-code-window.png"))
    click_button "Dual", exact: true
    expect(find('[aria-label="Markdown source"]')).to have_text("```javascript")
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(plan), wait: 10)
    expect(plan.reload.current_content).to include("```javascript\nconst answer = 42;\n```")
  end

  it "supports keyboard autocomplete, dismissal, and custom fence languages" do
    click_button "Insert code block"
    fill_in "coplan-insert-language", with: "type"
    find("#coplan-insert-language").send_keys(:enter)
    expect(find('[aria-label="Code language"]').value).to eq("typescript")
    draft = page.evaluate_script('document.querySelector("textarea[name=content]").value')
    click_button "Insert code block"
    find("#coplan-insert-language").send_keys(:escape)
    expect(page).not_to have_css("#coplan-insert-code:popover-open")
    expect(page).to have_css('[aria-label="Code language"]', count: 1)
    expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(draft)
    click_button "Insert code block"
    fill_in "coplan-insert-language", with: "java"
    find("#coplan-insert-language").send_keys(:arrow_down, :enter)
    expect(all('[aria-label="Code language"]').map(&:value)).to include("java")
    click_button "Insert code block"
    fill_in "coplan-insert-language", with: "custom-lang extra=1"
    click_button "Insert", exact: true
    expect(all('[aria-label="Code language"]').map(&:value)).to include("custom-lang extra=1")
  end

  it "uses the highlighted autocomplete choice when Insert is clicked" do
    click_button "Insert code block"
    fill_in "coplan-insert-language", with: "java"
    click_button "Insert", exact: true
    expect(find('[aria-label="Code language"]').value).to eq("javascript")
  end

  it "keeps the dropdown inside a narrow viewport" do
    original_size = page.current_window.size
    page.current_window.resize_to(390, 844)
    click_button "Insert code block"
    bounds = page.evaluate_script('(() => { const r = document.querySelector("#coplan-insert-code").getBoundingClientRect(); return { left: r.left, right: r.right, bottom: r.bottom, width: innerWidth, height: innerHeight } })()')
    expect(bounds["left"]).to be >= 0
    expect(bounds["right"]).to be <= bounds["width"]
    expect(bounds["bottom"]).to be <= bounds["height"]
    page.save_screenshot(Rails.root.join("tmp/editor-code-picker-mobile.png"))
  ensure
    page.current_window.resize_to(*original_size) if original_size
  end

  context "with an existing code block" do
    let(:source) { "Before prose.\n\n```ruby\nputs :other\n```\n\nAfter prose.\n" }

    it "deletes only the selected window and supports undo and redo in both panes" do
      click_button "Insert code block"
      find('[role="option"]', text: "JavaScript", exact_text: true).click
      page.driver.browser.action.send_keys("const keep = 1;").perform
      click_button "Dual", exact: true
      expect(page).not_to have_css(".document-editor__block-header label", text: "Language")
      find(".document-editor__code-window", text: "const keep = 1;").click_button("Delete code block")
      expect(page).to have_css(".document-editor__code-window", count: 1)
      expect(page).to have_css(".document-editor__code-window", text: "puts :other")
      expect(find('[aria-label="Markdown source"]')).not_to have_text("const keep")
      expect(find('[aria-label="Document body"]')).to have_text("Before prose.")
      expect(find('[aria-label="Document body"]')).to have_text("After prose.")
      click_button "Undo"
      expect(page).to have_css(".document-editor__code-window", text: "const keep = 1;")
      expect(all('[aria-label="Code language"]').map(&:value)).to eq([ "ruby", "javascript" ])
      click_button "Redo"
      expect(page).to have_css(".document-editor__code-window", count: 1)
      expect(page).to have_css(".document-editor__code-window", text: "puts :other")
      click_link "Back"
      expect(page).to have_current_path(plan_page_path(plan), wait: 10)
      expect(plan.reload.current_content).not_to include("const keep", "```javascript")
    end
  end
end
