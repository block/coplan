require "rails_helper"

RSpec.describe "Human plan editing", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Editable Plan", visibility: "published", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: "# Editable Plan\n\nFirst draft body.\n",
      actor_type: "human", actor_id: author.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")
  end

  before { sign_in(author) }

  def editor
    find('.ProseMirror[contenteditable="true"]', wait: 20)
  end

  def save_now
    modifier = RUBY_PLATFORM.include?("darwin") ? :meta : :control
    page.driver.browser.action.key_down(modifier).send_keys("s").key_up(modifier).perform
  end

  it "edits and formats the actual document, saving without navigation" do
    visit plan_edit_page_path(plan)
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Revised body from the browser.")
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ])
    click_button "Bold"
    expect(page).to have_css(".ProseMirror strong", text: "Revised body")
    save_now
    expect(page).to have_content("All changes saved · v2")
    expect(page).to have_current_path(plan_edit_page_path(plan))
    expect(plan.reload.current_content).to include("**Revised body from the browser.**")
    expect(plan.current_plan_version.actor_type).to eq("human")
  end

  it "edits title and tags atomically in place" do
    visit plan_edit_page_path(plan)
    editor
    # Use native selection/typing: Capybara's programmatic input.select() can
    # lose its range when Chrome refocuses the element before send_keys.
    modifier = RUBY_PLATFORM.include?("darwin") ? :meta : :control
    find("#plan_title").send_keys([ modifier, "a" ], "Renamed In Editor")
    find("summary", text: "Details").click
    fill_in "plan_tag_names", with: "security, api-design"
    save_now
    expect(page).to have_content("All changes saved · v1")
    expect(plan.reload.title).to eq("Renamed In Editor")
    expect(plan.tag_names).to contain_exactly("security", "api-design")
  end

  it "round trips untouched Markdown including unsupported constructs exactly" do
    visit plan_edit_page_path(plan)
    editor
    fixtures = [
      "# Heading\n\nSome **bold** and _italic_ text.\n",
      "# A\n\n```mermaid\ngraph TD; A-->B\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n",
      "[hello][ref]\n\n[ref]: https://example.com\n",
      "<details><summary>Note</summary>raw HTML</details>\n",
      "- [ ] task\n\nFootnote[^1]\n\n[^1]: footnote\n",
      "~~Strike~~ and [@sam](mention:sam)\n",
      "A\n\nB", "## Heading\nparagraph\n\n- A\n- B\n"
    ]
    results = page.evaluate_async_script(<<~'JS', fixtures)
      const [fixtures, done] = arguments;
      import("coplan/rich_document").then(m => done(fixtures.map(source => m.serializeDocument(m.parseDocument(source)))));
    JS
    expect(results).to eq(fixtures)
  end

  it "keeps untouched blocks exact when editing beside tables and Mermaid" do
    visit plan_edit_page_path(plan)
    editor
    source = "# Heading\n\nOriginal body.\n\n```mermaid\ngraph TD; A-->B\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
    result = page.evaluate_async_script(<<~'JS', source)
      const [source, done] = arguments;
      import("coplan/rich_document").then(m => {
        const host = document.createElement("div");
        const rich = m.createRichDocument(host, source, () => {});
        let position;
        rich.view.state.doc.descendants((node, pos) => { if (node.isText && node.text === "Original body.") position = pos; });
        rich.view.dispatch(rich.view.state.tr.insertText("Revised", position, position + 8));
        const result = rich.content(); rich.destroy(); done(result);
      });
    JS
    expect(result).to include("Revised body.")
    expect(result).to start_with("# Heading\n\n")
    expect(result).to end_with("```mermaid\ngraph TD; A-->B\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n")
  end

  it "retains a draft across reloads and clears it only after a successful save" do
    visit plan_edit_page_path(plan)
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Recovered draft")
    page.refresh # WebDriver accepts beforeunload automatically.
    expect(editor).to have_text("Recovered draft")
    # Recovery may autosave before the browser assertion runs.
    click_button "Reconnect edit lock" if page.has_button?("Reconnect edit lock", wait: 1)
    save_now
    expect(page).to have_content("All changes saved · v2")
    page.refresh
    expect(editor).to have_text("Recovered draft")
    expect(page).not_to have_content("Recovered an unsaved draft")
  end

  it "retains the draft when a save fails and restores it after reload" do
    visit plan_edit_page_path(plan)
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Keep this unsaved draft")
    page.execute_script(<<~'JS')
      const originalFetch = window.fetch;
      window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : originalFetch(url, options);
    JS
    save_now
    expect(page).to have_content("Offline")
    expect(plan.reload.current_revision).to eq(1)
    page.refresh
    expect(editor).to have_text("Keep this unsaved draft")
    save_now
    expect(page).to have_content("All changes saved · v2")
  end

  it "retains overlapping edits until the reviewed revision is explicitly replaced" do
    visit plan_edit_page_path(plan)
    editor
    page.execute_script('window.originalFetch = window.fetch; window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : window.originalFetch(url, options)')
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "My retained draft")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Intervening content", base_revision: 1,
      actor_type: "local_agent", actor_id: author.id)
    expect(page).to have_content("Both edits change", wait: 10)
    expect(editor).to have_text("My retained draft")
    expect(plan.reload.current_content).to eq("Intervening content")
    page.execute_script('window.fetch = window.originalFetch')
    accept_confirm { click_button "Replace reviewed version with my draft" }
    expect(page).to have_content("All changes saved · v3")
    click_link "Back"
    expect(page).to have_current_path(plan_page_path(plan))
    expect(plan.reload.edit_lease).to be_nil
  end

  it "autosaves and uses the same paragraph typography as reading view" do
    visit plan_page_path(plan)
    reading = page.evaluate_script('(() => { const s = getComputedStyle(document.querySelector(".markdown-rendered p")); return [s.fontSize, s.lineHeight, s.marginBottom] })()')
    visit plan_edit_page_path(plan)
    editor
    writing = page.evaluate_script('(() => { const s = getComputedStyle(document.querySelector(".ProseMirror p")); return [s.fontSize, s.lineHeight, s.marginBottom] })()')
    expect(writing).to eq(reading)
    expect(writing.last).not_to eq("0px")
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Autosaved from typing")
    expect(page).to have_content("All changes saved · v2", wait: 10)
    expect(plan.reload.current_content).to include("Autosaved from typing")
    expect(plan.edit_lease).to be_nil
    click_link "Back"
    expect(page).to have_css(".markdown-rendered", text: "Autosaved from typing")
    page.refresh
    expect(page).to have_css(".markdown-rendered", text: "Autosaved from typing")
  end

  it "handles Command and Control formatting, undo, redo and list shortcuts" do
    visit plan_edit_page_path(plan)
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Keyboard text")
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ])
    [ :meta, :control ].each do |modifier|
      editor.send_keys([ modifier, "b" ])
      expect(page).to have_css(".ProseMirror strong", text: "Keyboard text")
      expect(page).to have_css('[aria-label="Bold"][aria-pressed="true"]')
      editor.send_keys([ modifier, "z" ])
      expect(page).not_to have_css(".ProseMirror strong")
      editor.send_keys([ modifier, :shift, "z" ])
      expect(page).to have_css(".ProseMirror strong")
      editor.send_keys([ modifier, "b" ])
      editor.send_keys([ modifier, "i" ])
      expect(page).to have_css(".ProseMirror em")
      editor.send_keys([ modifier, "i" ])
    end
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, :shift, "8" ])
    expect(page).to have_css(".ProseMirror ul li")
    editor.send_keys(:right)
    editor.send_keys(:enter)
    editor.send_keys("Second item")
    expect(page).to have_css(".ProseMirror li", count: 2)
  end

  it "incorporates agent changes while preserving local undo and selection" do
    visit plan_edit_page_path(plan)
    editor
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      import("coplan/rich_document").then(m => {
        const host = document.createElement("div");
        const rich = m.createRichDocument(host, "Alpha paragraph.\n\nBeta paragraph.\n", () => {});
        rich.view.dispatch(rich.view.state.tr.insertText("HUMAN ", 1));
        const selection = rich.view.state.selection.from;
        rich.update("HUMAN Alpha paragraph.\n\nAGENT Beta paragraph.\n");
        const after = rich.content(), selected = rich.view.state.selection.from;
        rich.command("undo"); const undone = rich.content();
        rich.command("redo"); const redone = rich.content();
        rich.update(redone.replace("Beta", "**Beta**"));
        const formatted = rich.content();
        rich.destroy(); done({ after, selection, selected, undone, redone, formatted });
      }).catch(e => done({ error: e.stack }));
    JS
    expect(result["error"]).to be_nil
    expect(result["selected"]).to eq(result["selection"])
    expect(result["after"]).to include("HUMAN Alpha", "AGENT Beta")
    expect(result["undone"]).to include("Alpha", "AGENT Beta")
    expect(result["undone"]).not_to include("HUMAN")
    expect(result["redone"]).to include("HUMAN Alpha", "AGENT Beta")
    expect(result["formatted"]).to include("AGENT **Beta**")
  end

  it "keeps source-only and unsupported remote edits and undo within a formatted paragraph" do
    visit plan_edit_page_path(plan)
    editor
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      import("coplan/rich_document").then(m => {
        const rich = m.createRichDocument(document.createElement("div"), "Alpha and beta.", () => {});
        rich.view.dispatch(rich.view.state.tr.insertText("HUMAN ", 1));
        rich.update("HUMAN Alpha and **beta**.");
        rich.command("undo"); const undone = rich.content();
        rich.command("redo"); const redone = rich.content();
        rich.update("HUMAN Alpha and __beta__."); const spelling = rich.content();
        rich.update("| A | B |\n|---|---|\n| 1 | 2 |\n");
        rich.update("| A | B |\n|---|---|\n| 1 | 3 |\n"); const table = rich.content();
        rich.destroy(); done({undone, redone, spelling, table});
      }).catch(e => done({error:e.stack}));
    JS
    expect(result["error"]).to be_nil
    expect(result["undone"]).to eq("Alpha and **beta**.")
    expect(result["redone"]).to eq("HUMAN Alpha and **beta**.")
    expect(result["spelling"]).to eq("HUMAN Alpha and __beta__.")
    expect(result["table"]).to include("| 1 | 3 |")
  end

  it "preserves typing during a delayed save and then saves the newer draft" do
    visit plan_edit_page_path(plan)
    editor
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.fetch = async (url, options) => {
        const response = await original(url, options);
        if (options?.method === "PATCH") { window.saveStarted = true; await new Promise(resolve => setTimeout(resolve, 1800)); }
        return response;
      };
    JS
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "First edit")
    save_now
    expect(page).to have_content("Saving…")
    editor.send_keys(:end, " plus in-flight typing")
    expect(page).to have_content("All changes saved · v3", wait: 12)
    expect(plan.reload.current_content).to include("First edit plus in-flight typing")
    page.refresh
    expect(editor).to have_text("First edit plus in-flight typing")
  end

  it "reconciles a committed save whose response was lost without making another version" do
    visit plan_edit_page_path(plan)
    editor
    page.execute_script(<<~'JS')
      const original = window.fetch;
      window.allowSnapshots = false;
      window.fetch = async (url, options) => {
        if (url.includes("editor_state") && !window.allowSnapshots) throw new TypeError("Disconnected");
        const response = await original(url, options);
        if (options?.method === "PATCH" && !window.lostResponse) {
          window.lostResponse = true;
          throw new TypeError("Connection lost after commit");
        }
        return response;
      };
    JS
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "Committed despite lost response")
    save_now
    expect(page).to have_content("Connection lost after commit")
    expect(plan.reload.current_revision).to eq(2)
    page.execute_script('window.allowSnapshots = true; window.dispatchEvent(new Event("online"))')
    expect(page).not_to have_content("Not saved", wait: 10)
    expect(editor).to have_text("Committed despite lost response")
    expect(plan.reload.current_revision).to eq(2)
  end

  it "merges a live agent update with an unsaved human edit" do
    visit plan_edit_page_path(plan)
    editor
    # Prevent the human patch long enough to receive a real server version.
    page.execute_script('window.originalFetch = window.fetch; window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new TypeError("Offline")) : window.originalFetch(url, options)')
    editor.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, :end ], " Human addition.")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "# Agent heading\n\nFirst draft body.\n", base_revision: 1,
      actor_type: "local_agent", actor_id: author.id)
    expect(editor).to have_text("Agent heading", wait: 10)
    expect(editor).to have_text("Human addition.")
    page.execute_script('window.fetch = window.originalFetch; window.dispatchEvent(new Event("online"))')
    expect(page).to have_content("All changes saved · v3", wait: 10)
    expect(plan.reload.current_content).to include("Agent heading", "Human addition.")
  end

  def open_plan_menu
    find("#plan-toolbar button[aria-label='More actions']").click
    expect(page).to have_css("#plan-menu:popover-open")
  end

  it "changes visibility from the overflow menu in place, no reload" do
    plan.update!(visibility: "draft")
    visit plan_page_path(plan)

    # Private is the rare state — the byline flags it.
    expect(page).to have_css("#plan-header .state-flag", text: "Private")

    open_plan_menu
    within("#plan-menu") { click_button "Share with everyone" }

    # The Turbo Stream re-renders the header in place: the Private flag
    # drops without a navigation, and a toast confirms.
    expect(page).to have_content("Shared with everyone in the org.")
    expect(page).not_to have_css("#plan-header .state-flag", text: "Private")
    expect(plan.reload.visibility).to eq("published")

    # The menu tracks state: it now offers the opposite direction.
    open_plan_menu
    within("#plan-menu") { click_button "Make private" }
    expect(page).to have_content("Private again — hidden from lists and search.")
    expect(page).to have_css("#plan-header .state-flag", text: "Private")
    expect(plan.reload.visibility).to eq("draft")
  end

  it "archives and restores the plan in place" do
    visit plan_page_path(plan)
    expect(page).to have_css(".plan-location-link--nav", visible: :all)

    open_plan_menu
    within("#plan-menu") { click_button "Archive plan" }

    # The consequence is visible right where it happened: a banner with the
    # undo, no navigation away from the document.
    expect(page).to have_css(".plan-banner--archived", text: "hidden from lists")
    expect(page).to have_content("Editable Plan")
    expect(page).not_to have_css(".plan-location-link", visible: :all)
    expect(plan.reload.archived?).to be(true)

    # Archive leaves the menu while archived.
    open_plan_menu
    expect(page).not_to have_button("Archive plan")
    find("#plan-toolbar button[aria-label='More actions']").click # close menu

    within(".plan-banner--archived") { click_button "Restore" }
    expect(page).not_to have_css(".plan-banner--archived")
    expect(page).to have_css(".plan-location-link--nav", visible: :all)
    expect(plan.reload.archived?).to be(false)
  end

  it "hides owner controls from non-authors" do
    other = create(:coplan_user, email: "viewer@example.com")
    click_button "Menu"
    click_link "Sign out"
    sign_in(other)

    visit plan_page_path(plan)
    expect(page).to have_content("Editable Plan")
    # A reader gets the overflow menu and nothing else. There used to be a
    # Save here that filed the plan onto their own shelf; a plan lives in
    # one place now, so reading one is just reading it.
    within("#plan-toolbar") do
      expect(page).not_to have_link("Edit")
      expect(page).not_to have_button("Save")
    end
    # The reader's overflow menu is History only — no state-changing actions.
    open_plan_menu
    within("#plan-menu") do
      expect(page).to have_link("History")
      expect(page).not_to have_button("Archive plan")
      expect(page).not_to have_button("Make private")
      expect(page).not_to have_button("Share with everyone")
      expect(page).not_to have_button("Move to folder…")
    end
  end
end
