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

  it "keeps the visible source passage and page position when opening and closing Preview" do
    click_button "Raw", exact: true
    block_saves
    long_source = "# Long source\n\n" + (1..100).map { |n| "Paragraph #{n}: #{'A long sentence to exercise line wrapping. ' * 5}\n\n" }.join
    raw.send_keys([ mod, "a" ])
    page.execute_script(<<~JS, raw, long_source)
      const clipboard = new DataTransfer(); clipboard.setData("text/plain", arguments[1]);
      arguments[0].dispatchEvent(new ClipboardEvent("paste", {clipboardData: clipboard, bubbles: true, cancelable: true}));
    JS
    page.execute_script(<<~JS, long_source.index("Paragraph 60:"))
      window.previewEditor = Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor");
      previewEditor.rawEditor.select(arguments[0]);
    JS
    2.times do
      page.execute_script(<<~JS)
        const rect = previewEditor.rawSurfaceTarget.getBoundingClientRect();
        const top = Math.max(rect.top, previewEditor.toolbarTarget.getBoundingClientRect().bottom, 0) + 2;
        window.sourceAnchor = previewEditor.rawEditor.view.posAtCoords({left: rect.left + 8, top}).pos;
        window.sourceTop = previewEditor.rawEditor.view.coordsAtPos(sourceAnchor).top;
        window.sourcePageY = window.scrollY;
      JS
      click_button "Preview", exact: true
      expect(page.evaluate_script("previewEditor.rawEditor.view.coordsAtPos(sourceAnchor).top")).to be_within(2).of(page.evaluate_script("sourceTop"))
      expect(page.evaluate_script("window.scrollY")).to be_within(2).of(page.evaluate_script("sourcePageY"))
    end
  end

  it "reveals linked slides and retains the selected slide during refresh" do
    open_preview
    block_saves
    deck = "# Deck preview\n\n[Jump to second](#second-slide)\n\n::: {.presentation}\n\n# First slide\n\nFirst slide content.\n\n---\n\n# Second slide\n\nSecond slide content.\n\n:::\n"
    raw.send_keys([ mod, "a" ], deck)
    expect(preview).to have_css('.deck-slide--current', text: "First slide content.")
    preview.click_link "Jump to second"
    expect(preview).to have_css('.deck-slide--current', text: "Second slide content.")
    expect(preview).not_to have_css('.deck-slide--current', text: "First slide content.")
    expect(page).not_to have_current_path(/#coplan-preview-/)
    raw.send_keys([ mod, "a" ], deck.sub("Deck preview", "Updated deck preview"))
    expect(preview).to have_css('h1', text: "Updated deck preview")
    expect(preview).to have_css('.deck-slide--current', text: "Second slide content.")
  end

  it "renders when newer AbortSignal composition helpers are unavailable" do
    page.execute_script("Object.defineProperty(AbortSignal, 'any', {value: undefined}); Object.defineProperty(AbortSignal, 'timeout', {value: undefined})")
    open_preview
    expect(preview).to have_text("Original prose")
  end

  it "reveals nested disclosures and preserves their open and closed state through refresh" do
    open_preview
    block_saves
    details = "# Details preview\n\n[Jump inside](#inside)\n\n<details>\n<summary>Outer</summary>\n\n<details>\n<summary>Inner</summary>\n\n## Inside\n\nOriginal detail.\n\n</details>\n</details>\n"
    raw.send_keys([ mod, "a" ], details)
    expect(preview).to have_css("summary", text: "Outer")
    preview.click_link "Jump inside"
    expect(preview).to have_css("details[open]", count: 2)
    expect(preview).to have_text("Original detail.")
    raw.send_keys([ mod, "a" ], details.sub("Original detail.", "Changed detail."))
    expect(preview).to have_text("Changed detail.")
    expect(preview).to have_css("details[open]", count: 2)
    preview.find("summary", text: "Inner", exact_text: true).click
    raw.send_keys([ mod, "a" ], details.sub("Original detail.", "Latest detail."))
    expect(preview).to have_css("details[open]", count: 1)
    expect(preview).not_to have_text("Latest detail.")
  end

  it "dismisses a keyboard-opened reference card before local navigation" do
    open_preview
    citation = preview.find("[data-footnote-ref]")
    raw.send_keys(:tab)
    citation.execute_script("this.focus()")
    expect(page).to have_css(".reference-preview:popover-open", wait: 5)
    citation.send_keys(:enter)
    expect(page).not_to have_css(".reference-preview:popover-open")
    expect(citation["aria-expanded"]).to eq("false")
    expect(page).not_to have_current_path(/#coplan-preview-/)
  end

  it "returns from scrolled Raw source to the same passage in the reader" do
    content = "# Long document\n\n" + (1..80).map { |n| "Passage #{n} has **formatted words** and supporting text.\n\n" }.join
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content, base_revision: plan.current_revision,
      actor_type: "local_agent", actor_id: author.id)
    click_button "Raw", exact: true
    expect(raw).to have_text("Passage 60")
    page.execute_script(<<~JS, content.index("Passage 60"))
      const editor = Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor");
      editor.rawEditor.select(arguments[0]);
      window.rawExitAnchor = editor.rawViewportAnchor();
    JS
    anchor = page.evaluate_script("rawExitAnchor")
    expect(anchor).not_to be_nil
    expect(anchor.fetch("text")).to include("Passage")
    find(".document-editor__close-inline").click
    expect(page).not_to have_css("form.document-editor")
    passage = find("#plan-content-body p", text: anchor.fetch("text"), exact_text: true)
    expect(passage.evaluate_script("(() => { const range = document.createRange(); range.setStart(this.firstChild, 0); range.collapse(true); return range.getBoundingClientRect().top })()")).to be_within(3).of(anchor.fetch("top"))
  end

  it "keeps the visible line when leaving a long Raw code block" do
    content = "# Long code\n\n```text\n" + (1..80).map { |n| "Line #{n}: content to keep in view.\n" }.join + "```\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content, base_revision: plan.current_revision,
      actor_type: "local_agent", actor_id: author.id)
    click_button "Raw", exact: true
    expect(raw).to have_text("Line 40:")
    page.execute_script(<<~JS, content.index("Line 40:"))
      const editor = Stimulus.getControllerForElementAndIdentifier(document.querySelector("form.document-editor"), "coplan--editor");
      editor.rawEditor.select(arguments[0]);
      const surface = editor.rawSurfaceTarget, view = editor.rawEditor.view;
      surface.scrollTop += view.coordsAtPos(arguments[0] + 1).top - surface.getBoundingClientRect().top - 5;
      window.lineTop = view.coordsAtPos(arguments[0] + 1).top;
    JS
    top = page.evaluate_script("lineTop")
    find(".document-editor__close-inline").click
    expect(page).not_to have_css("form.document-editor")
    code = find("#plan-content-body pre code", text: "Line 40:")
    expect(code.evaluate_script("(() => { const range = document.createRange(); range.setStart(this.firstChild, this.textContent.indexOf('Line 40:')); range.collapse(true); return range.getBoundingClientRect().top })()")).to be_within(3).of(top)
  end

  it "routes citation-card links into Preview and dismisses cards on pane scrolling" do
    open_preview
    block_saves
    content = source.sub("Current draft footnote.", "[Inside details](#inside-details)") + "\n<details>\n<summary>More</summary>\n\n## Inside details\n\nHidden target.\n\n</details>\n"
    raw.send_keys([ mod, "a" ], content)
    expect(preview).to have_css("summary", text: "More")
    citation = preview.find("[data-footnote-ref]")
    raw.send_keys(:tab)
    citation.execute_script("this.focus()")
    expect(page).to have_css(".reference-preview:popover-open")
    page.execute_script("arguments[0].scrollTop += 20", preview)
    expect(page).not_to have_css(".reference-preview:popover-open")
    raw.send_keys(:tab)
    citation.execute_script("this.focus()")
    expect(page).to have_css(".reference-preview:popover-open")
    within(".reference-preview:popover-open") { click_link "Inside details" }
    expect(preview).to have_text("Hidden target.")
    expect(page).not_to have_css(".reference-preview:popover-open")
    expect(page).not_to have_current_path(/#coplan-preview-/)
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
