require "rails_helper"

RSpec.describe "Editor toolbar", type: :system do
  let(:author) { create(:coplan_user, email: "editor-toolbar@example.com") }
  let(:plan) { CoPlan::Plans::Create.call(title: "Toolbar test", content: "Original prose.\n", user: author, visibility: "draft", actor_type: "human") }
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css('[aria-label="Document body"]', wait: 20)
    expect(page).to have_css('.document-editor__save-status[data-state="idle"]')
  end

  def raw
    find('[aria-label="Markdown source"]')
  end

  def status
    find(".document-editor__save-status")
  end

  it "shows saving through in-flight typing, then fades the acknowledged autosave without moving the toolbar" do
    click_button "Raw", exact: true
    bounds = status.rect
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.savedBodies = [];
      window.saveStates = [];
      const status = document.querySelector('.document-editor__save-status');
      new MutationObserver(() => window.saveStates.push({
        state: status.dataset.state, title: status.title,
        queuedVisible: getComputedStyle(status.querySelector('.document-editor__save-queued')).display !== 'none'
      })).observe(status, { attributes: true, attributeFilter: ['data-state'] });
      const firstSave = new Promise(resolve => { window.finishSave = resolve; });
      window.fetch = async (url, options) => {
        if (options?.method !== "PATCH") return original(url, options);
        window.savedBodies.push(JSON.parse(options.body));
        const response = await original(url, options);
        if (window.savedBodies.length === 1) await firstSave;
        return response;
      };
    JS
    raw.send_keys([ mod, "a" ], "First edit")
    expect(page).to have_css('.document-editor__save-status[data-state="saving"] .document-editor__save-spinner')
    expect(status["title"]).to eq("Saving…")
    expect(page.evaluate_script("window.saveStates")).to include(
      { "state" => "queued", "title" => "Saving soon…", "queuedVisible" => true },
      { "state" => "saving", "title" => "Saving…", "queuedVisible" => false }
    )
    raw.send_keys(:right, " and newer typing")
    expect(status["data-state"]).to eq("saving")
    page.execute_script("window.finishSave()")
    expect(page).to have_css('.document-editor__save-status[data-state="saved"]', wait: 10)
    expect(plan.reload.current_content).to eq("First edit and newer typing")
    expect(status["title"]).to include("All changes saved · v3")
    expect(page).to have_css('.document-editor__save-status[aria-live="polite"][aria-atomic="true"]')
    expect(status.rect).to eq(bounds)
    expect(page.evaluate_script("window.savedBodies.every(body => !('change_summary' in body))")).to eq(true)
    # Wait for the real CSS animation rather than asserting only a class name.
    expect(page).to have_css(".document-editor__save-check", visible: :all, wait: 5) { |check| check.style("opacity")["opacity"] == "0" }
    raw.send_keys(:right, " again")
    expect(page).to have_css('.document-editor__save-status[data-state="saved"][title*="v4"]', wait: 10)
    expect(page).to have_css(".document-editor__save-check")
    expect(plan.reload.current_content).to end_with("again")
    page.save_screenshot(Rails.root.join("tmp/editor-toolbar-raw.png"))
  end

  it "clears the queued icon when undo returns to the saved draft before autosave" do
    click_button "Raw", exact: true
    # Both native key sequences occur within the debounce, without a test sleep.
    raw.send_keys([ mod, "a" ], "Temporary edit", [ mod, "z" ])
    expect(raw).to have_text("Original prose.")
    expect(page).to have_css('.document-editor__save-status[data-state="idle"]')
    expect(page).not_to have_css(".document-editor__save-queued")
    expect(plan.reload.current_revision).to eq(1)
  end

  it "keeps save errors visible while typing and recovers after retry" do
    click_button "Raw", exact: true
    page.execute_script('window.originalFetch = window.fetch; window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : window.originalFetch(url, options)')
    raw.send_keys([ mod, "a" ], "Retained draft")
    expect(page).to have_css('.document-editor__save-status[data-state="error"]', text: "Not saved · draft retained")
    expect(page).to have_content("Offline")
    raw.send_keys(:right, " with more")
    expect(status["data-state"]).to eq("error")
    expect(plan.reload.current_revision).to eq(1)
    page.execute_script("window.fetch = window.originalFetch")
    click_button "Retry sync"
    expect(page).to have_css('.document-editor__save-status[data-state="saved"]', wait: 10)
    expect(page).not_to have_content("Offline")
    expect(plan.reload.current_content).to eq("Retained draft with more")
  end

  it "keeps formatting visible but disabled for raw focus and restores it for rich focus" do
    click_button "Dual", exact: true
    raw.click
    expect(page).to have_css('[role="toolbar"]')
    expect(page).to have_css('select[aria-label="Paragraph style"]:disabled')
    expect(page).to have_button("Bold", disabled: true)
    expect(page).to have_button("Insert code block", disabled: true)
    raw.send_keys([ mod, "a" ], "Raw changes")
    expect(page).to have_button("Undo", disabled: false)
    click_button "Undo"
    expect(raw).to have_text("Original prose.")
    expect(page).to have_button("Bold", disabled: true)
    click_button "Redo"
    expect(raw).to have_text("Raw changes")
    find('[aria-label="Document body"]').click
    expect(page).to have_css('select[aria-label="Paragraph style"]:enabled')
    expect(page).to have_button("Bold", disabled: false)
    expect(page).to have_button("Insert code block", disabled: false)
    find('[aria-label="Document body"]').send_keys([ mod, "a" ])
    click_button "Bold"
    expect(raw).to have_text("**Raw changes**")
    click_button "Raw", exact: true
    expect(page).to have_css('[role="toolbar"]')
    expect(page).to have_button("Bold", disabled: true)
    expect(raw).to have_text("**Raw changes**")
    click_button "Editor", exact: true
    expect(page).to have_button("Bold", disabled: false)
  end

  it "does not show an autosave check for incoming edits and retains their tags on the next save" do
    plan.update!(tag_names: [ "remote-tag" ])
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Incoming prose.", base_revision: 1, actor_type: "local_agent", actor_id: author.id)
    expect(page).to have_css('[aria-label="Document body"]', text: "Incoming prose.", wait: 10)
    expect(status["data-state"]).to eq("idle")
    expect(page).not_to have_css(".document-editor__save-check")
    click_button "Raw", exact: true
    raw.send_keys([ mod, "a" ], "Human follow-up")
    expect(page).to have_css('.document-editor__save-status[data-state="saved"]', wait: 10)
    expect(plan.reload.current_content).to eq("Human follow-up")
    expect(plan.tag_names).to eq([ "remote-tag" ])
  end

  it "keeps the save indicator at the right edge when controls wrap on a narrow screen" do
    original_size = page.current_window.size
    page.current_window.resize_to(390, 844)
    bounds = page.evaluate_script(<<~'JS')
      (() => {
        const toolbar = document.querySelector('.document-editor__toolbar').getBoundingClientRect();
        const status = document.querySelector('.document-editor__save-status').getBoundingClientRect();
        return { gap: toolbar.right - status.right, top: status.top - toolbar.top, right: toolbar.right, width: innerWidth };
      })()
    JS
    expect(bounds["gap"]).to be_between(0, 15)
    expect(bounds["top"]).to be_between(0, 15)
    expect(bounds["right"]).to be <= bounds["width"]
    page.save_screenshot(Rails.root.join("tmp/editor-toolbar-mobile.png"))
  ensure
    page.current_window.resize_to(*original_size) if original_size
  end
end
