require "rails_helper"

RSpec.describe "Document editor modes", type: :system do
  let(:author) { create(:coplan_user, email: "editor-modes@example.com") }
  let(:source) { "# Draft\n\nOriginal prose.\n\n| Item | State |\n|---|---|\n| Draft | Ready |\n\n```mermaid\ngraph LR; A-->B\n```\n\n```ruby\nputs :hello\n```\n" }
  let(:plan) do
    CoPlan::Plans::Create.call(title: "Mode test", content: source, user: author, visibility: "draft", actor_type: "human")
  end
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  def open_editor
    visit plan_edit_page_path(plan)
    expect(page).to have_css('.document-editor__body .ProseMirror[contenteditable="true"]', wait: 20)
    expect(page).to have_content("All changes saved")
  end

  def raw
    find('[aria-label="Markdown source"]')
  end

  def save_now
    page.driver.browser.action.key_down(mod).send_keys("s").key_up(mod).perform
  end

  def block_saves
    page.execute_script('window.originalFetch = window.fetch; window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : window.originalFetch(url, options)')
  end

  it "previews tables and diagrams and switches source modes without rewriting a byte" do
    open_editor
    expect(page).to have_css(".document-editor__block table", text: "Ready")
    expect(page).to have_css(".document-editor__block .mermaid-diagram svg", wait: 20)
    expect(page).not_to have_button("Save")
    expect(page).not_to have_link("Done")
    expect(page).not_to have_content("Edit origin")
    find(".document-editor__block", text: "Table ·").click_button("Edit Markdown")
    expect(raw).to have_text("| Draft | Ready |")
    expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(source)
    click_button "Editer"
    click_button "Raw", exact: true
    expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(source)
    save_now
    expect(page).to have_content("All changes saved · v1")
    expect(plan.reload.current_revision).to eq(1)
    expect(plan.current_content).to eq(source)
  end

  it "saves exact unsupported Markdown from raw mode and returns through Back" do
    open_editor
    block_saves
    click_button "Raw", exact: true
    replacement = source.sub("Ready", "Approved") + "\n<details><summary>More</summary>Exact HTML</details>\n\nNote[^1]\n\n[^1]: retained\n"
    raw.send_keys([ mod, "a" ], replacement)
    click_button "Editer"
    click_button "Raw", exact: true
    expect(raw.text).to include("Approved", "[^1]: retained")
    # A pre-save hover must not cache the old reading page for Back.
    find_link("Back").hover
    sleep 0.25 # Turbo hover prefetch waits 100ms.
    page.execute_script("window.fetch = window.originalFetch")
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to eq(replacement)
    expect(page).to have_css("table", text: "Approved")
    page.refresh
    expect(page).to have_css("table", text: "Approved")
  end

  it "keeps the draft in place when Back fails, then retries and navigates" do
    open_editor
    block_saves
    click_button "Raw", exact: true
    raw.send_keys([ mod, "a" ], "Retain this draft")
    click_link "Back"
    expect(page).to have_content("Offline")
    expect(page).to have_current_path(plan_edit_page_path(plan))
    expect(raw).to have_text("Retain this draft")
    expect(plan.reload.current_revision).to eq(1)
    page.execute_script('window.fetch = window.originalFetch')
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to eq("Retain this draft")
  end

  it "waits for a save in flight before going Back" do
    open_editor
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.fetch = async (url, options) => {
        const response = await original(url, options);
        if (options?.method === "PATCH") await new Promise(resolve => setTimeout(resolve, 1500));
        return response;
      };
    JS
    click_button "Raw", exact: true
    raw.send_keys([ mod, "a" ], "Before request")
    save_now
    expect(page).to have_content("Saving…")
    raw.send_keys(:right, " and in flight")
    click_link "Back"
    expect(page).to have_current_path(plan_edit_page_path(plan))
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to eq("Before request and in flight")
  end

  it "blocks Back on overlapping changes in raw mode" do
    open_editor
    block_saves
    click_button "Raw", exact: true
    raw.send_keys([ mod, "a" ], "Local replacement")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Remote replacement", base_revision: 1, actor_type: "local_agent", actor_id: author.id)
    expect(page).to have_content("Both edits change", wait: 10)
    click_link "Back"
    expect(page).to have_content("Resolve the conflict before going back")
    expect(page).to have_current_path(plan_edit_page_path(plan))
    expect(raw).to have_text("Local replacement")
    expect(plan.reload.current_content).to eq("Remote replacement")
  end

  it "merges live raw edits and retains local undo across an incoming agent change" do
    open_editor
    block_saves
    click_button "Raw", exact: true
    raw.send_keys([ mod, :end ], "\nHuman tail")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source.sub("Original prose.", "Agent prose."), base_revision: 1, actor_type: "local_agent", actor_id: author.id)
    expect(raw).to have_text("Agent prose.", wait: 10)
    expect(raw).to have_text("Human tail")
    raw.send_keys([ mod, "z" ])
    expect(raw).not_to have_text("Human tail")
    expect(raw).to have_text("Agent prose.")
    raw.send_keys([ mod, :shift, "z" ])
    expect(raw).to have_text("Human tail")
    click_button "Editer"
    expect(page).to have_css(".document-editor__body .ProseMirror", text: "Agent prose.")
    page.execute_script('window.fetch = window.originalFetch')
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("Agent prose.", "Human tail")
  end

  it "exits the final code block with ArrowDown or a click without altering untouched source" do
    open_editor
    expect(plan.reload.current_content).to eq(source)
    code = all(".document-editor__block > pre > code").last
    code.click
    code.send_keys([ mod, :right ])
    code.send_keys(:arrow_down, "Outside code")
    expect(page).to have_css(".ProseMirror > p", text: "Outside code")
    expect(page).not_to have_css(".document-editor__block pre", text: "Outside code")
    find(".document-editor__body .ProseMirror > p:last-child").click
    page.driver.browser.action.send_keys("Clicked below").perform
    expect(page).to have_css(".ProseMirror > p", text: "Clicked below")
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("```ruby\nputs :hello\n```", "Outside code", "Clicked below")
  end

  it "changes code language, preserves Mermaid content and supports undo and raw round trips" do
    open_editor
    language = all('[aria-label="Code language"]').last
    language.fill_in(with: "python")
    language.send_keys(:tab)
    click_button "Raw", exact: true
    expect(raw).to have_text("```python")
    expect(raw).to have_text("puts :hello")
    click_button "Editer"
    click_button "Undo"
    expect(all('[aria-label="Code language"]').last.value).to eq("ruby")
    click_button "Redo"
    expect(all('[aria-label="Code language"]').last.value).to eq("python")
    all('[aria-label="Code language"]').first.fill_in(with: "text")
    expect(page).not_to have_css(".document-editor__block .mermaid-diagram")
    all('[aria-label="Code language"]').first.fill_in(with: "mermaid")
    expect(page).to have_css(".document-editor__block .mermaid-diagram svg", wait: 20)
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("```python", "puts :hello", "```mermaid", "graph LR; A-->B")
  end

  it "preserves code language undo across an incoming edit to the code" do
    open_editor
    block_saves
    all('[aria-label="Code language"]').last.send_keys([ mod, "a" ], "python")
    expect(all('[aria-label="Code language"]').last.value).to eq("python")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source.sub("puts :hello", "puts :agent"), base_revision: 1,
      actor_type: "local_agent", actor_id: author.id)
    expect(page).to have_css(".document-editor__block pre", text: "puts :agent", wait: 10)
    expect(all('[aria-label="Code language"]').last.value).to eq("python")
    click_button "Undo"
    expect(all('[aria-label="Code language"]').last.value).to eq("ruby")
    expect(page).to have_css(".document-editor__block pre", text: "puts :agent")
    click_button "Redo"
    expect(all('[aria-label="Code language"]').last.value).to eq("python")
    click_button "Raw", exact: true
    expect(raw).to have_text("```python")
    expect(raw).to have_text("puts :agent")
  end

  it "uses themed native style options and the app's outline link icon" do
    open_editor
    expect(page).to have_css('[aria-label="Link"] svg path', count: 2)
    %w[dark light].each do |theme|
      page.execute_script('document.documentElement.dataset.theme = arguments[0]', theme)
      colors = page.evaluate_script(<<~'JS')
        (() => { const select = document.querySelector('[aria-label="Paragraph style"]'), option = select.options[0];
          return [getComputedStyle(select).colorScheme, getComputedStyle(select).backgroundColor, getComputedStyle(option).backgroundColor, getComputedStyle(select).color]; })()
      JS
      expect(colors.first).to eq(theme)
      expect(colors[1]).to eq(colors[2])
      expect(colors[1]).not_to eq(colors[3])
      find('select[aria-label="Paragraph style"]').select("Code block")
      expect(page).to have_css('[aria-label="Code language"]')
      find('select[aria-label="Paragraph style"]').select("Heading 1")
    end
  end

  it "retains a raw draft and its mode through reload, then saves it" do
    open_editor
    block_saves
    click_button "Raw", exact: true
    raw.send_keys([ mod, "a" ], "Retained raw **draft**.")
    fill_in "plan_title", with: "Recovered source title"
    save_now
    expect(page).to have_content("Offline")
    page.refresh
    expect(raw).to have_text("Retained raw **draft**.")
    expect(find("#plan_title").value).to eq("Recovered source title")
    expect(page).to have_content("All changes saved", wait: 10)
    expect(plan.reload.current_content).to eq("Retained raw **draft**.")
  end

  it "keeps Back on invalid fields and allows valid source mode to save" do
    open_editor
    fill_in "plan_title", with: ""
    click_link "Back"
    expect(page).to have_current_path(plan_edit_page_path(plan))
    expect(page).to have_content("Correct the highlighted field")
    fill_in "plan_title", with: plan.title
    all('[aria-label="Code language"]').last.fill_in(with: "ruby`")
    click_link "Back"
    expect(page).to have_current_path(plan_edit_page_path(plan))
    click_button "Raw", exact: true
    raw.send_keys([ mod, :end ], "\nValid source edit")
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("Valid source edit")
  end

  it "creates a new document through autosave without replacing its editor" do
    visit new_plan_path
    expect(page).to have_css('.document-editor__body .ProseMirror[contenteditable="true"]', wait: 20)
    click_button "Raw", exact: true
    raw.send_keys("# New source\n\nUntouched **Markdown**.")
    fill_in "plan_title", with: "Autosaved new source"
    expect(page).to have_content("All changes saved · v1", wait: 15)
    expect(raw).to have_text("Untouched **Markdown**.")
    created = CoPlan::Plan.find_by!(title: "Autosaved new source")
    expect(page).to have_current_path(plan_edit_page_path(created))
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(created))
    expect(created.current_plan_version.actor_type).to eq("human")
  end
  it "keeps both panes synchronized, scopes selection, and saves one revision" do
    open_editor
    block_saves
    click_button "Dual", exact: true
    expect(page).not_to have_content("Write below")
    expect(all(".document-editor__block").last).not_to have_button("Edit Markdown")
    raw.send_keys([ mod, "a" ], "# Shared draft\n\nHuman **words**.\n\n```javascript\nfunction hi() {\n}\n```\n")
    expect(page).to have_css(".document-editor__body h1", text: "Shared draft")
    expect(page.evaluate_script('document.activeElement.getAttribute("aria-label")')).to eq("Markdown source")
    rich = find('[aria-label="Document body"]')
    rich.find("p", text: "Human words.").click
    page.driver.browser.action.key_down(mod).send_keys(:right).key_up(mod).send_keys(" More.").perform
    expect(raw).to have_text("More.")
    # Native controls nested inside NodeView chrome must keep native Select All.
    language = find('[aria-label="Code language"]')
    language.send_keys([ mod, "a" ], "custom-lang extra=1")
    expect(language.value).to eq("custom-lang extra=1")
    expect(raw).to have_text("```custom-lang extra=1")
    page.save_screenshot(Rails.root.join("tmp/editor-dual.png"))
    title = find("#plan_title")
    title.send_keys([ mod, "a" ], "Selection stays local")
    expect(title.value).to eq("Selection stays local")
    expect(raw).to have_text("Shared draft")
    rich.find("p", text: "Human words.").click
    page.driver.browser.action.key_down(mod).send_keys("a").key_up(mod).perform
    expect(page.evaluate_script('document.querySelector("[aria-label=\"Document body\"]").contains(getSelection().anchorNode)')).to eq(true)
    expect(page.evaluate_script('getSelection().toString()')).to include("Shared draft")
    # Focus a control outside either editor: default browser selection is allowed.
    find(".document-editor__menu summary").click
    page.execute_script('window.addEventListener("keydown", event => { if (event.key === "a") window.selectAllEvent = { target: event.target.tagName, prevented: event.defaultPrevented } })')
    page.driver.browser.action.key_down(mod).send_keys("a").key_up(mod).perform
    expect(page.evaluate_script('window.selectAllEvent')).to eq({ "prevented" => false, "target" => "SUMMARY" })
    page.execute_script('window.savedRequests = 0; window.fetch = (url, options) => { if (options?.method === "PATCH") window.savedRequests++; return window.originalFetch(url, options) }')
    click_link "Back"
    expect(page).to have_current_path(/selection-stays-local$/, wait: 15)
    expect(plan.reload.current_revision).to eq(2)
    expect(plan.current_content).to include("More.", "custom-lang extra=1")
    expect(page.evaluate_script("window.savedRequests")).to eq(1)
  end

  it "maps dual undo and selection through a disjoint incoming agent edit" do
    open_editor
    block_saves
    click_button "Dual", exact: true
    raw.send_keys([ mod, :end ], "\nHuman tail")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source.sub("Original prose.", "Agent prose."), base_revision: 1, actor_type: "local_agent", actor_id: author.id)
    expect(raw).to have_text("Agent prose.", wait: 10)
    expect(find('[aria-label="Document body"]')).to have_text("Agent prose.")
    expect(page.evaluate_script('document.activeElement.getAttribute("aria-label")')).to eq("Markdown source")
    raw.send_keys([ mod, "z" ])
    expect(raw).not_to have_text("Human tail")
    expect(find('[aria-label="Document body"]')).not_to have_text("Human tail")
    expect(raw).to have_text("Agent prose.")
    raw.send_keys([ mod, :shift, "z" ])
    expect(raw).to have_text("Human tail")
    click_button "Raw", exact: true
    click_button "Editer", exact: true
    click_button "Dual", exact: true
    expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(source.sub("Original prose.", "Agent prose.") + "\nHuman tail")
  end

  it "retains both panes and the dual preference after a failed Back and recovery" do
    open_editor
    block_saves
    click_button "Dual", exact: true
    raw.send_keys([ mod, "a" ], "Retained dual **draft**.")
    click_link "Back"
    expect(page).to have_content("Offline")
    expect(find('[aria-label="Document body"]')).to have_text("Retained dual draft.")
    page.refresh
    expect(raw).to have_text("Retained dual **draft**.")
    expect(find('[aria-label="Document body"]')).to have_text("Retained dual draft.")
    expect(page).to have_content("All changes saved", wait: 10)
    expect(plan.reload.current_content).to eq("Retained dual **draft**.")
  end

  it "retains both drafts on overlapping live changes in Dual" do
    open_editor
    block_saves
    click_button "Dual", exact: true
    raw.send_keys([ mod, "a" ], "Local replacement")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Remote replacement", base_revision: 1, actor_type: "local_agent", actor_id: author.id)
    expect(page).to have_content("Both edits change", wait: 10)
    click_link "Back"
    expect(page).to have_content("Resolve the conflict before going back")
    expect(raw).to have_text("Local replacement")
    expect(find('[aria-label="Document body"]')).to have_text("Local replacement")
    expect(plan.reload.current_content).to eq("Remote replacement")
  end

  it "defers counterpart updates until composition completes and stacks panes on narrow screens" do
    open_editor
    block_saves
    click_button "Dual", exact: true
    raw.click
    page.execute_script('document.activeElement.dispatchEvent(new CompositionEvent("compositionstart", {bubbles: true}))')
    raw.send_keys([ mod, "a" ], :right, " composed")
    expect(raw).to have_text("composed")
    expect(find('[aria-label="Document body"]')).not_to have_text("composed")
    page.execute_script('document.activeElement.dispatchEvent(new CompositionEvent("compositionend", {bubbles: true, data: "composed"}))')
    expect(find('[aria-label="Document body"]')).to have_text("composed")
    page.driver.browser.manage.window.resize_to(600, 900)
    panes = page.evaluate_script('Array.from(document.querySelectorAll(".document-editor__raw, .document-editor__body"), e => e.getBoundingClientRect().toJSON())')
    expect(panes[1]["top"]).to be >= panes[0]["bottom"]
    expect(panes[1]["width"]).to be <= 600
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  it "defers an in-flight remote response through composition without losing the composed draft" do
    open_editor
    block_saves
    click_button "Dual", exact: true
    page.execute_script(<<~'JS')
      const prior = window.fetch;
      window.fetch = async (url, options) => {
        const response = await prior(url, options);
        if (String(url).includes("editor_state") && !window.releaseRemote) await new Promise(resolve => { window.releaseRemote = resolve });
        return response;
      };
    JS
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source.sub("Original prose.", "Agent prose."), base_revision: 1, actor_type: "local_agent", actor_id: author.id)
    Selenium::WebDriver::Wait.new(timeout: 5).until { page.evaluate_script('!!window.releaseRemote') }
    raw.send_keys([ mod, "a" ], :right)
    page.execute_script('document.activeElement.dispatchEvent(new CompositionEvent("compositionstart", {bubbles:true}))')
    raw.send_keys(" Composed tail")
    page.execute_script('window.releaseRemote()')
    expect(raw).to have_text("Original prose.")
    expect(raw).to have_text("Composed tail")
    page.execute_script('document.activeElement.dispatchEvent(new CompositionEvent("compositionend", {bubbles:true, data:"Composed tail"}))')
    expect(raw).to have_text("Agent prose.", wait: 10)
    expect(raw).to have_text("Composed tail")
    expect(find('[aria-label="Document body"]')).to have_text("Composed tail")
    expect(page.evaluate_script('document.activeElement.getAttribute("aria-label")')).to eq("Markdown source")
  end
end
