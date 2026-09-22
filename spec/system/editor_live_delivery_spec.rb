require "rails_helper"

RSpec.describe "Editor live cable delivery", type: :system do
  let(:author) { create(:coplan_user, email: "editor-live@example.com") }
  let(:source) { "# Live\n\nAgent section.\n\nHuman section.\n" }
  let(:plan) { CoPlan::Plans::Create.call(title: "Live delivery", content: source, user: author, visibility: "draft", actor_type: "human") }
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css('[aria-label="Document body"]', wait: 20)
    expect(page).to have_css('turbo-cable-stream-source[connected]', visible: :all, minimum: 2, wait: 10)
    Selenium::WebDriver::Wait.new(timeout: 5).until do
      page.evaluate_script('!!Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor").poll')
    end
    page.execute_script(<<~'JS')
      const c = Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor");
      clearInterval(c.poll); c.poll = null;
      window.deliveredStreams=[];
      document.addEventListener("turbo:before-stream-render", event => window.deliveredStreams.push(event.target.getAttribute("target")));
    JS
  end

  def agent_write(content)
    CoPlan::Plans::ReplaceContent.call(plan: plan.reload, new_content: content, base_revision: plan.current_revision,
      actor_type: "local_agent", actor_id: author.id)
  end

  [ "Editer", "Raw", "Dual" ].each do |mode|
    it "receives a real broadcast in #{mode} with polling disabled" do
      click_button mode, exact: true
      agent_write(source.sub("Agent section.", "Committed background edit."))
      expect(page).to have_content("Committed background edit.", wait: 5)
      expect(page.evaluate_script('window.deliveredStreams')).to include("plan-content-body", "plan-history-list")
      expect(page.evaluate_script('Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor").poll')).to be_nil
    end
  end

  it "merges a dirty disjoint Dual draft and retains it on the next overlapping broadcast" do
    click_button "Dual", exact: true
    page.execute_script('window.originalFetch=window.fetch;window.fetch=(url,options)=>options?.method==="PATCH"?Promise.reject(new Error("Offline")):window.originalFetch(url,options)')
    raw = find('[aria-label="Markdown source"]')
    raw.send_keys([ mod, "a" ], source.sub("Human section.", "Human local edit."))
    agent_write(source.sub("Agent section.", "Agent remote edit."))
    expect(raw).to have_text("Agent remote edit.", wait: 5)
    expect(raw).to have_text("Human local edit.")
    expect(find('[aria-label="Document body"]')).to have_text("Human local edit.")
    agent_write(plan.reload.current_content.sub("Human section.", "Conflicting remote edit."))
    expect(page).to have_content("Both edits change", wait: 5)
    expect(raw).to have_text("Human local edit.")
    expect(plan.reload.current_content).to include("Conflicting remote edit.")
  end

  it "queues a real broadcast while a save response is in flight" do
    click_button "Dual", exact: true
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.fetch=async (url,options)=>{const response=await original(url,options);if(options?.method==="PATCH") await new Promise(resolve=>window.releaseSave=resolve);return response};
    JS
    find('[aria-label="Markdown source"]').send_keys([ mod, "a" ], source.sub("Human section.", "Human saved edit."))
    page.driver.browser.action.key_down(mod).send_keys("s").key_up(mod).perform
    Selenium::WebDriver::Wait.new(timeout: 5).until { page.evaluate_script('!!window.releaseSave') }
    agent_write(plan.reload.current_content.sub("Agent section.", "Agent during save."))
    page.execute_script('window.releaseSave()')
    expect(page).to have_content("Agent during save.", wait: 5)
    expect(page).to have_content("Human saved edit.")
    expect(plan.reload.current_content).to include("Agent during save.", "Human saved edit.")
  end

  it "drains a second committed broadcast received during an older snapshot request" do
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.fetch=async (url,options)=>{
        const response=await original(url,options);
        if(options?.method==="GET" && !window.releaseSnapshot) await new Promise(resolve=>window.releaseSnapshot=resolve);
        return response;
      };
    JS
    agent_write(source.sub("Agent section.", "First remote commit."))
    Selenium::WebDriver::Wait.new(timeout: 5).until { page.evaluate_script('!!window.releaseSnapshot') }
    agent_write(source.sub("Agent section.", "Second remote commit."))
    Selenium::WebDriver::Wait.new(timeout: 5).until do
      page.evaluate_script('Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor").refreshPending')
    end
    page.execute_script('window.releaseSnapshot()')
    expect(page).to have_content("Second remote commit.", wait: 5)
  end
end

RSpec.describe "New document live delivery", type: :system do
  let(:author) { create(:coplan_user, email: "new-editor-live@example.com") }
  let(:source) { "# New live document\n\nAgent section.\n\nHuman section.\n" }
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  it "connects an in-place creation, merges real broadcasts, reconnects and cleans up without polling" do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit new_plan_path
    expect(page).to have_css('[aria-label="Document body"]', wait: 20)
    fill_in "plan_title", with: "Created live"
    click_button "Dual", exact: true
    raw = find('[aria-label="Markdown source"]')
    raw.send_keys(source)
    expect(page).to have_content("All changes saved · v1", wait: 10)
    created = CoPlan::Plan.find_by!(title: "Created live")
    expect(page).to have_current_path(plan_edit_page_path(created))
    page.execute_script(<<~'JS')
      const c = Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor");
      clearInterval(c.poll); c.poll = null;
      window.originalFetch = window.fetch;
      window.fetch = (url,options) => options?.method === "PATCH" ? Promise.reject(new Error("Offline")) : window.originalFetch(url,options);
      window.deliveredStreams = [];
      document.addEventListener("turbo:before-stream-render", event => window.deliveredStreams.push(event.target.getAttribute("target")));
    JS
    expect(page).to have_css('form.document-editor turbo-cable-stream-source[connected]', visible: :all, count: 1, wait: 10)
    page.execute_script(<<~'JS')
      window.createdSource = document.querySelector("form.document-editor turbo-cable-stream-source");
      window.createdSubscription = window.createdSource.subscription;
      window.createdConsumer = window.createdSubscription.consumer;
    JS
    raw.send_keys([ mod, "a" ], source.sub("Human section.", "Human unsaved draft."))
    CoPlan::Plans::ReplaceContent.call(plan: created.reload, new_content: source.sub("Agent section.", "Agent broadcast after creation."),
      base_revision: created.current_revision, actor_type: "local_agent", actor_id: author.id)
    expect(raw).to have_text("Agent broadcast after creation.", wait: 5)
    expect(raw).to have_text("Human unsaved draft.")
    expect(find('[aria-label="Document body"]')).to have_text("Human unsaved draft.")
    expect(page.evaluate_script('window.deliveredStreams')).to include("plan-content-body", "plan-history-list")
    page.execute_script('window.fetch = window.originalFetch')
    page.driver.browser.action.key_down(mod).send_keys("s").key_up(mod).perform
    expect(page).to have_content("All changes saved", wait: 10)

    page.execute_script('window.createdConsumer.disconnect()')
    expect(page).not_to have_css('form.document-editor turbo-cable-stream-source[connected]', visible: :all)
    CoPlan::Plans::ReplaceContent.call(plan: created.reload, new_content: created.current_content.sub("Agent broadcast after creation.", "Agent edit while disconnected."),
      base_revision: created.current_revision, actor_type: "local_agent", actor_id: author.id)
    page.execute_script('window.createdConsumer.connect()')
    expect(page).to have_css('form.document-editor turbo-cable-stream-source[connected]', visible: :all, count: 1, wait: 10)
    expect(raw).to have_text("Agent edit while disconnected.", wait: 5)
    [ "Editer", "Raw", "Dual" ].each { |mode| click_button mode, exact: true }
    expect(page.evaluate_script('window.createdConsumer.subscriptions.subscriptions.filter(s => s.identifier === window.createdSubscription.identifier).length')).to eq(1)
    expect(page.evaluate_script('Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor").poll')).to be_nil
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(created), wait: 10)
    expect(page.evaluate_script('window.createdSource.isConnected')).to eq(false)
    expect(page.evaluate_script('window.createdConsumer.subscriptions.subscriptions.includes(window.createdSubscription)')).to eq(false)
  end
end
