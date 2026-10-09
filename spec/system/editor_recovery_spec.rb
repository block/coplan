require "rails_helper"

RSpec.describe "Editor draft recovery", type: :system do
  let(:author) { create(:coplan_user, email: "editor-recovery@example.com") }
  let(:plan) { CoPlan::Plans::Create.call(title: "Recovery", content: "Saved content", user: author, actor_type: "human") }
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }
  let(:legacy_key) { "coplan-editor-draft-#{plan.id}" }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  def store(key, data)
    page.execute_script("localStorage.setItem(arguments[0], JSON.stringify(arguments[1]))", key, data)
  end

  def rich
    find('[aria-label="Document body"]', wait: 20)
  end

  [ 1, 0 ].each do |revision|
    it "retains a legacy revision #{revision} draft while showing a conflict state" do
      store(legacy_key, { content: "Legacy content", revision: revision })
      visit plan_edit_page_path(plan)
      expect(rich).to have_text("Saved content")
      click_button "Review older draft"
      expect(rich).to have_text("Legacy content")
      expect(page).to have_css('.document-editor__close-inline[data-state="conflict"][aria-label="Conflict — reload document"]')
      expect(plan.reload.current_content).to eq("Saved content")
      page.refresh
      expect(rich).to have_text("Saved content")
      expect(page).to have_button("Review older draft")
      expect(page.evaluate_script("localStorage.getItem(arguments[0])", legacy_key)).to be_present
      click_button "Review older draft"
      expect(rich).to have_text("Legacy content")
      expect(page).to have_css('.document-editor__close-inline[data-state="conflict"][aria-label="Conflict — reload document"]')
      expect(plan.reload.current_content).to eq("Saved content")
      expect(page.evaluate_script("localStorage.getItem(arguments[0])", legacy_key)).to be_present
    end
  end

  it "does not replace a newer scoped draft and retains it when reviewing an older copy" do
    base = { content: plan.current_content, title: plan.title, tags: "", revision: 1 }
    store("coplan-rich-draft-#{author.id}-#{plan.id}-existing", base.merge(content: "Newer draft", base: base, reviewRequired: true))
    store(legacy_key, { content: "Older draft", revision: 1 })
    visit plan_edit_page_path(plan)
    expect(rich).to have_text("Newer draft")
    click_button "Review older draft"
    expect(rich).to have_text("Older draft")
    expect(page.evaluate_script('Object.values(localStorage).some(raw => { try { return JSON.parse(raw).content === "Newer draft" } catch { return false } })')).to eq(true)
    expect(plan.reload.current_content).to eq("Saved content")
  end

  it "waits for an in-flight save before installing a legacy draft that needs consent" do
    store(legacy_key, { content: "Legacy content", revision: 1 })
    visit plan_edit_page_path(plan)
    rich
    page.execute_script(<<~'JS')
      const original = window.fetch, gate = new Promise(resolve => { window.releaseSave = resolve; });
      window.fetch = async (url, options) => {
        const response = await original(url, options);
        if (options?.method === 'PATCH') await gate;
        return response;
      };
    JS
    rich.send_keys([ mod, "a" ], "Newer content")
    expect(page).to have_css('[data-coplan--editor-target="status"][data-state="saving"]')
    click_button "Review older draft"
    expect(rich).to have_text("Newer content")
    page.execute_script("window.releaseSave()")
    expect(rich).to have_text("Legacy content")
    expect(page).to have_css('.document-editor__close-inline[data-state="conflict"][aria-label="Conflict — reload document"]')
    expect(plan.reload.current_content).to eq("Newer content")
    page.driver.browser.action.key_down(mod).send_keys("s").key_up(mod).perform
    expect(page).to have_css('.document-editor__close-inline[data-state="conflict"][aria-label="Conflict — reload document"]')
    expect(plan.reload.current_content).to eq("Newer content")
  end

  it "preserves a deliberately blank recovered title" do
    base = { content: plan.current_content, title: plan.title, tags: "", revision: 1 }
    store("coplan-rich-draft-#{author.id}-#{plan.id}-existing", base.merge(title: "", base: base))
    visit plan_edit_page_path(plan)
    rich
    expect(find("#plan-header .inline-editor__title").text).to eq("")
    expect(page).to have_content("Add a document title to save")
    expect(plan.reload.title).to eq("Recovery")
  end

  it "recovers an unsaved new plan after signing in again without reloading" do
    visit new_plan_path
    rich
    page.execute_script(<<~'JS')
      const original = window.fetch;
      const meta = document.querySelector('meta[name="csrf-token"]') || document.head.appendChild(document.createElement('meta'));
      meta.name = 'csrf-token'; meta.content = 'expired';
      window.signedOut = true;
      window.fetch = async (url, options) => {
        if (window.signedOut && options?.method === 'POST' && JSON.parse(options.body || '{}').creation_key) return new Response('{}', {status: 401, headers: {'Content-Type': 'application/json'}});
        if (options?.method === 'POST' && JSON.parse(options.body || '{}').creation_key && options.headers['X-CSRF-Token'] === 'expired') return new Response('Old token', {status: 422, headers: {'Content-Type': 'text/html'}});
        return original(url, options);
      };
    JS
    find("#plan-header .inline-editor__title").send_keys("Recovered new plan")
    rich.send_keys("Retained creation draft")
    expect(page).to have_content("Sign in again · draft retained", wait: 10)
    expect(author.created_plans.where(title: "Recovered new plan")).to be_empty
    page.execute_script('window.signedOut = false')
    click_button "Retry sync", enable_aria_label: true
    expect(page).to have_content("All changes saved · v1", wait: 15)
    expect(author.created_plans.where(title: "Recovered new plan").count).to eq(1)
    expect(author.created_plans.find_by!(title: "Recovered new plan").current_content).to include("Retained creation draft")
  end

  it "retries a lost creation response after reload without duplication or losing newer typing" do
    visit new_plan_path
    rich
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.fetch = async (url, options) => {
        const response = await original(url, options);
        if (options?.method === 'POST' && JSON.parse(options.body || '{}').creation_key) throw new TypeError('Lost creation reply');
        return response;
      };
    JS
    find("#plan-header .inline-editor__title", wait: 10).send_keys("One document")
    click_button "Raw", exact: true
    raw = find('[aria-label="Markdown source"]')
    raw.send_keys("First draft")
    expect(page).to have_css('.document-editor__close-inline[data-state="error"][aria-label="Retry sync"]', wait: 10)
    created = author.created_plans.find_by!(title: "One document")
    raw.send_keys(:right, " and newer typing")
    page.refresh
    raw = find('[aria-label="Markdown source"]', wait: 20)
    expect(raw).to have_text("First draft and newer typing")
    raw.click
    page.driver.browser.action.key_down(mod).send_keys("s").key_up(mod).perform
    expect(page).to have_content("All changes saved · v2", wait: 15)
    expect(author.created_plans.where(title: "One document").count).to eq(1)
    expect(created.reload.current_content).to eq("First draft and newer typing")
  end
end
