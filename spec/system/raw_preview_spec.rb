require "rails_helper"

RSpec.describe "Raw reader preview", type: :system do
  let(:author) { create(:coplan_user, email: "raw-preview@example.com") }
  let(:source) do
    <<~MD
      # Preview tryout

      Original **prose** with a note.[^note]

      ## Details

      | Step | Owner |
      | --- | --- |
      | Review | Team |

      - [ ] Read-only task

      ```markdown
      # Literal heading
      **This stays code**
      ```

      ```mermaid
      graph LR
        A[Draft] --> B[Review]
      ```

      [^note]: Current draft footnote.
    MD
  end
  let(:plan) { CoPlan::Plans::Create.call(content: source, user: author, visibility: "draft", actor_type: "human") }
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css('[aria-label="Document body"]', wait: 20)
  end

  def raw = find('[aria-label="Markdown source"]')
  def preview = find('[aria-label="Reader preview"]')

  def open_preview
    click_button "Raw", exact: true
    click_button "Preview", exact: true
    expect(preview).to have_css(".markdown-rendered")
  end

  def block_saves
    page.execute_script('window.originalFetch = window.fetch; window.fetch = (url, options) => options?.method === "PATCH" ? Promise.reject(new Error("Offline")) : window.originalFetch(url, options)')
  end

  it "offers only two modes and previews the reader while keeping Markdown fences literal" do
    expect(page).not_to have_button("Dual")
    expect(page).not_to have_button("Preview", exact: true)
    revision = plan.current_revision
    open_preview
    expect(preview).to have_css("strong", text: "prose")
    expect(preview).to have_css("table td", text: "Review")
    expect(preview).to have_css("input[type=checkbox]:disabled")
    expect(preview).to have_css(".mermaid-diagram svg", wait: 15)
    expect(preview).to have_css("pre code", text: "# Literal heading")
    expect(preview).not_to have_css("h1", text: "Literal heading")
    expect(preview).to have_text("Current draft footnote.")
    expect(preview).not_to have_css('[contenteditable="true"]')
    expect(plan.reload.current_revision).to eq(revision)
    expect(page.evaluate_script('document.querySelector("textarea[name=content]").value')).to eq(source)
    click_button "Preview", exact: true
    expect(page).not_to have_css('[aria-label="Reader preview"]')
    expect(raw).to have_text("# Literal heading")
  end

  it "refreshes unsaved source without taking focus and keeps Raw undo and redo" do
    open_preview
    block_saves
    raw.send_keys([ mod, "a" ], source.sub("Original", "Changed"))
    expect(preview).to have_text("Changed prose")
    expect(page.evaluate_script('document.activeElement.getAttribute("aria-label")')).to eq("Markdown source")
    expect(plan.reload.current_content).to eq(source)
    raw.send_keys([ mod, "z" ])
    expect(preview).to have_text("Original prose")
    raw.send_keys([ mod, :shift, "z" ])
    expect(preview).to have_text("Changed prose")
    click_button "Editor", exact: true
    expect(page).not_to have_css('[aria-label="Reader preview"]')
    expect(find('[aria-label="Document body"]')).to have_text("Changed prose")
    click_button "Raw", exact: true
    expect(raw).to have_text("Changed **prose**")
    expect(page).not_to have_css('[aria-label="Reader preview"]')
  end

  it "shows a failed refresh without discarding the last preview and retries" do
    open_preview
    block_saves
    page.execute_script(<<~JS)
      const prior = window.fetch;
      window.fetch = (url, options) => String(url).includes('preview_draft') && !window.allowPreview
        ? Promise.resolve(new Response('', { status: 500 })) : prior(url, options);
    JS
    raw.send_keys([ mod, "a" ], source.sub("Original", "Retried"))
    expect(preview).to have_text("Could not refresh preview")
    expect(preview).to have_text("Original prose")
    page.execute_script("window.allowPreview = true")
    click_button "Retry preview"
    expect(preview).to have_text("Retried prose")
    expect(preview).not_to have_button("Retry preview")
  end

  it "ignores an older response after Raw returns to the already rendered source", browser_sync: :manual do
    open_preview
    block_saves
    page.execute_script(<<~JS)
      const prior = window.fetch;
      window.fetch = async (url, options) => {
        if (!String(url).includes('preview_draft')) return prior(url, options);
        const response = await prior(url, {...options, signal: undefined});
        await response.clone().text();
        return new Promise(resolve => window.releasePreview = () => resolve(response));
      };
    JS
    raw.send_keys([ mod, "a" ], source.sub("Original", "Delayed"))
    Selenium::WebDriver::Wait.new(timeout: 10).until { page.evaluate_script("!!window.releasePreview") }
    raw.send_keys([ mod, "a" ], source)
    page.execute_script("window.releasePreview()")
    expect(preview).to have_text("Original prose")
    expect(preview).not_to have_text("Delayed prose")
    expect(preview["aria-busy"]).to be_nil
  end

  it "merges live agent changes while retaining a disjoint Raw edit" do
    open_preview
    block_saves
    page.execute_script(<<~JS, source.length)
      const editor = Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor");
      editor.rawEditor.select(arguments[0]);
    JS
    raw.send_keys("\nHuman tail\n")
    CoPlan::Plans::ReplaceContent.call(plan: plan.reload, new_content: source.sub("Original", "Agent"),
      base_revision: plan.current_revision, actor_type: "local_agent", actor_id: author.id)
    expect(raw).to have_text("Agent **prose**", wait: 10)
    expect(preview).to have_text("Agent prose", wait: 10)
    expect(preview).to have_text("Human tail")
    raw.send_keys([ mod, "z" ])
    expect(preview).not_to have_text("Human tail")
    expect(raw).to have_text("Agent **prose**")
  end

  it "defers a remote response during composition without losing the Raw draft", browser_sync: :manual do
    open_preview
    block_saves
    page.execute_script(<<~JS)
      const prior = window.fetch;
      window.fetch = async (url, options) => {
        const response = await prior(url, options);
        if (String(url).includes("editor_state") && !window.releaseRemote) await new Promise(resolve => { window.releaseRemote = resolve });
        return response;
      };
    JS
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: source.sub("Original", "Agent"),
      base_revision: plan.current_revision, actor_type: "local_agent", actor_id: author.id)
    Selenium::WebDriver::Wait.new(timeout: 5).until { page.evaluate_script("!!window.releaseRemote") }
    page.execute_script(<<~JS, source.length)
      const editor = Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor");
      editor.rawEditor.select(arguments[0]);
      document.activeElement.dispatchEvent(new CompositionEvent("compositionstart", {bubbles: true}));
    JS
    raw.send_keys(" Composed tail")
    page.execute_script("window.releaseRemote()")
    expect(raw).to have_text("Original **prose**")
    expect(raw).to have_text("Composed tail")
    page.execute_script('document.activeElement.dispatchEvent(new CompositionEvent("compositionend", {bubbles: true, data: "Composed tail"}))')
    expect(raw).to have_text("Agent **prose**", wait: 10)
    expect(preview).to have_text("Agent prose")
    expect(preview).to have_text("Composed tail")
    expect(page.evaluate_script('document.activeElement.getAttribute("aria-label")')).to eq("Markdown source")
  end

  it "migrates a stored Dual mode to Raw without opening a preview" do
    page.execute_script("sessionStorage.setItem(arguments[0], 'dual')", "coplan-editor-mode-#{author.id}")
    page.refresh
    expect(page).to have_css('[data-mode="markdown"][aria-pressed="true"]')
    expect(raw).to have_text("Original **prose**")
    expect(page).not_to have_css('[aria-label="Reader preview"]')
    click_button "Preview", exact: true
    expect(preview).to have_text("Original prose")
    page.refresh
    expect(raw).to have_text("Original **prose**")
    expect(page).not_to have_css('[aria-label="Reader preview"]')
  end

  it "keeps footnote navigation inside the draft and leaves the page position alone" do
    open_preview
    block_saves
    raw.send_keys([ mod, "a" ], source.sub("Current draft footnote.", "Revised footnote."))
    expect(preview).to have_text("Revised footnote.")
    citation = preview.find("[data-footnote-ref]")
    old_y = page.evaluate_script("window.scrollY")
    citation.click
    expect(preview).to have_text("Revised footnote.")
    expect(page.evaluate_script("window.scrollY")).to be_within(2).of(old_y)
    expect(preview.evaluate_script("this.scrollTop")).to be > 0
  end

  it "stacks usable scrollable panes on a phone without horizontal overflow" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    open_preview
    panes = page.evaluate_script("[...document.querySelectorAll('.document-editor__raw, .document-editor__preview')].map(el => el.getBoundingClientRect().toJSON())")
    expect(panes[1]["top"]).to be >= panes[0]["bottom"]
    expect(panes[0]["height"]).to be > 150
    expect(panes[1]["height"]).to be > 150
    expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 390
    expect(page).to have_button("Preview", exact: true)
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
