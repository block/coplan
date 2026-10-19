require "rails_helper"

RSpec.describe "Writing provenance", type: :system do
  let(:user) { create(:coplan_user, email: "writing@example.com") }
  let(:plan) { CoPlan::Plans::Create.call(title: "Writing sources", content: "# Delivery\n\nExisting agent proposal.\n", user: user, actor_type: "local_agent", agent_name: "Claude") }

  after { page.current_window.resize_to(1400, 900) }

  def open_editor
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu", wait: 20)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".inline-editor [contenteditable=true]")
    expect(page).to have_text("All changes saved")
  end

  def writing_kind(text)
    snapshot = plan.reload.current_plan_version.writing_provenance
    offset = plan.current_content.index(text)
    raise "Missing #{text}" unless offset
    cursor = 0
    run = snapshot.fetch("runs").find { |length, _| cursor += length; cursor > offset }
    snapshot.fetch("sources").fetch(run.last).fetch("kind")
  end

  it "keeps mixed typed and pasted citation text separate from retained agent writing" do
    content = "Read source[^ref].\n\n[^ref]: Original evidence.\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content, base_revision: 1, actor_type: "local_agent", actor_id: user.id)
    open_editor
    click_button "Edit citation ref", enable_aria_label: true
    body = find('#coplan-citation-body')
    body.send_keys([ :control, "a" ], "typedcitation ")
    page.execute_script(<<~JS, body)
      const field = arguments[0]
      const pasted = 'pastedcitation😀\\nhttps://pasted.example.com'
      field.setRangeText(pasted, field.selectionStart, field.selectionEnd, 'end')
      field.dispatchEvent(new InputEvent('input', {inputType:'insertFromPaste', data:pasted, bubbles:true}))
    JS
    body.send_keys(" humanending")
    click_button "Save citation"
    expect(page).to have_no_css('dialog[open]', wait: 20)
    expect(writing_kind("Read source")).to eq("ai")
    expect(writing_kind("typedcitation")).to eq("human")
    expect(writing_kind("pastedcitation")).to eq("unknown")
    expect(writing_kind("😀")).to eq("unknown")
    expect(writing_kind("https://pasted.example.com")).to eq("unknown")
    expect(writing_kind("humanending")).to eq("human")
  end

  it "leaves native link-prompt input unknown and distinguishes pasted code-language fields" do
    content = "# Delivery\n\nLink label\n\n```ruby\nputs 'hello'\n```\n"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content, base_revision: 1, actor_type: "local_agent", actor_id: user.id)
    open_editor
    page.execute_script(<<~JS)
      const node = document.querySelector('[aria-label="Document body"] p').firstChild
      const range = document.createRange(); range.selectNodeContents(node)
      const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range)
      document.querySelector('[aria-label="Document body"]').focus()
    JS
    accept_prompt(with: "https://pasted.example.com") { click_button "Link", exact: true, enable_aria_label: true }
    expect(page).to have_css('#writing-provenance[data-coplan--writing-provenance-revision-value="3"]', wait: 20)
    expect(writing_kind("pasted.example.com")).to eq("unknown")
    language = find('[aria-label="Code language"]')
    page.execute_script(<<~JS, language)
      arguments[0].value = 'pasted-language'
      arguments[0].dispatchEvent(new InputEvent('input', {inputType:'insertFromPaste', bubbles:true}))
    JS
    expect(page).to have_css('#writing-provenance[data-coplan--writing-provenance-revision-value="4"]', wait: 20)
    expect(writing_kind("pasted-language")).to eq("unknown")
  end

  it "explains the inspection limit while keeping named percentages usable" do
    plan
    stub_const("CoPlan::Plans::WritingProvenance::MAX_INSPECTION_CHARACTERS", 4)
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu", wait: 20)
    visit plan_page_path(plan)
    find(".writing-provenance__trigger").click
    expect(page).to have_css(".writing-provenance__counts", text: "Claude")
    click_button "Inspect writing"
    expect(page).to have_css('[role="status"]', text: "Writing percentages are still available")
    expect(page).to have_button("Inspect writing", disabled: false)
    expect(page).to have_no_button("Done inspecting")
  end

  it "opens details and toggles source highlights without changing document layout" do
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu", wait: 20)
    visit plan_page_path(plan)
    top = page.evaluate_script("document.getElementById('plan-content-body').getBoundingClientRect().top")
    find(".writing-provenance__trigger").click
    expect(page).to have_css(".writing-provenance__counts", text: "Claude")
    expect(page).to have_no_text("AI agents and models")
    click_button "Inspect writing"
    expect(page).to have_button("Done inspecting")
    expect(page.evaluate_script("CSS.highlights.get('coplan-writing-ai').size")).to be_positive
    expect(page.evaluate_script("document.getElementById('plan-content-body').getBoundingClientRect().top")).to eq(top)
    click_button "Done inspecting"
    expect(page.evaluate_script("CSS.highlights.has('coplan-writing-ai')")).to be(false)
    find(".writing-provenance__trigger").click
    page.current_window.resize_to(390, 844)
    expect(page.evaluate_script("document.querySelector('.writing-provenance__panel').getBoundingClientRect().right <= document.documentElement.clientWidth - 8")).to be(true)
  end


  it "updates the provenance through streams while saving and after closing the editor" do
    open_editor
    surface = find('[aria-label="Document body"]')
    surface.click
    surface.send_keys([ :control, :end ], :end, " fresh human words")
    expect(page).to have_text("All changes saved", wait: 20)
    expect(page).to have_css('#writing-provenance[data-coplan--writing-provenance-revision-value="2"]', wait: 15)
    expect(page).to have_css("#plan-version-label", text: "v2")
    find(".writing-provenance__trigger").click
    expect(page).to have_button("Finish editing to inspect", disabled: true)
    within("#plan-toolbar") { click_link "Done" }
    expect(page).to have_no_css('.inline-editor form.document-editor', wait: 20)
    find(".writing-provenance__trigger").click
    expect(page).to have_css(".writing-provenance__counts", text: user.name)
    expect(page).to have_no_text("Current text")
    expect(page).to have_button("Inspect writing", disabled: false)
  end

  it "shows the actor and version for a one-word edit, and blocks editing until inspection ends" do
    original = plan.current_content
    changed = original.sub("Existing", "Existing not")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: changed, base_revision: 1, actor_type: "human", actor_id: user.id,
      input_sources: { "runs" => [ [ changed.length, "human" ] ] })
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu", wait: 20)
    visit plan_page_path(plan)
    find(".writing-provenance__trigger").click
    click_button "Inspect writing"
    expect(page).to have_button("Done inspecting")
    point = page.evaluate_script(<<~JS)
      (() => {
      const root = document.querySelector('#plan-content-body p')
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
      let node; while(node = walker.nextNode()) {
        const at = node.textContent.indexOf('not')
        if (at < 0) continue
        const range = document.createRange(); range.setStart(node, at); range.setEnd(node, at + 3)
        const rect = range.getBoundingClientRect(); return {x:rect.x + rect.width / 2, y:rect.y + rect.height / 2}
      }
      })()
    JS
    page.driver.browser.execute_cdp("Input.dispatchMouseEvent", type: "mouseMoved", x: point.fetch("x"), y: point.fetch("y"))
    expect(page).to have_css('.writing-inspection__tooltip:popover-open', text: "Added in v2")
    expect(find('.writing-inspection__tooltip')).to have_text(user.name)
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_no_css('.inline-editor form.document-editor', wait: 20)
    click_button "Done inspecting"
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css('.inline-editor [contenteditable=true]')
  end

  %w[rich markdown].each do |mode|
    it "records typing and paste separately in #{mode} mode and retains them after reload" do
      open_editor
      click_button "Raw", exact: true if mode == "markdown"
      # Exercise the browser's actual paste handler and keyboard input.
      surface = mode == "markdown" ? find('[aria-label="Markdown source"]') : find('[aria-label="Document body"]')
      surface.click
      surface.send_keys([ :control, :end ])
      surface.send_keys(:end, " humaninput")
      page.execute_script(<<~JS, surface)
        const clipboard = new DataTransfer()
        clipboard.setData('text/plain', ' pastedunknown')
        arguments[0].dispatchEvent(new ClipboardEvent('paste', {clipboardData: clipboard, bubbles: true, cancelable: true}))
      JS
      expect(page).to have_text("All changes saved", wait: 15)
      expect(plan.reload.current_content).to include("humaninput", "pastedunknown")
      counts = plan.writing_provenance_summary.fetch("counts")
      expect(counts.fetch("human")).to be >= 10
      expect(counts.fetch("unknown")).to be >= 13
      expect(counts.fetch("ai")).to be_positive
      before = plan.writing_provenance_summary.fetch("counts")
      visit plan_page_path(plan)
      expect(plan.reload.writing_provenance_summary.fetch("counts")).to eq(before)
    end
  end

  it "preserves pasted origins through tracker recovery, history, and Unicode edits" do
    open_editor
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0]
      import('coplan/input_origins').then(({InputOrigins}) => {
        const tracker = new InputOrigins('base ')
        tracker.record('base human', 'human')
        tracker.record('base human pasted😀', 'unknown')
        const restored = new InputOrigins(tracker.content, tracker.draft())
        const first = restored.payload()
        restored.record('base human pasted😀 typed', 'human')
        restored.payload()
        restored.record('base human pasted😀', 'history')
        done({first, undone:restored.payload(), length:restored.content.length})
      }).catch(error => done({error:error.message}))
    JS
    expect(result).not_to have_key("error")
    expect(result.fetch("first")).to eq(result.fetch("undone"))
    expect(result.fetch("first").fetch("runs").sum(&:first)).to eq(result.fetch("length"))
    expect(result.fetch("first").fetch("runs").map(&:last)).to include("human", "unknown")
  end

  it "keeps new pasted text unknown after the historical editor backfill" do
    plan.current_plan_version.update_columns(actor_type: "human", agent_name: nil, writing_provenance: nil)
    plan.update_columns(writing_provenance_backfill: { "legacy_revision" => 1, "revision" => 0 })
    CoPlan::WritingProvenanceJob.perform_now(plan_id: plan.id, restart: true)
    expect(plan.reload.writing_provenance_summary.dig("shares", "human")).to eq(1.0)
    open_editor
    surface = find('[aria-label="Document body"]')
    surface.click
    surface.send_keys([ :control, :end ], :end)
    page.execute_script(<<~JS, surface)
      const clipboard = new DataTransfer()
      clipboard.setData('text/plain', ' pastedunknown')
      arguments[0].dispatchEvent(new ClipboardEvent('paste', {clipboardData: clipboard, bubbles: true, cancelable: true}))
    JS
    expect(page).to have_css('#writing-provenance[data-coplan--writing-provenance-revision-value="2"]', wait: 20)
    expect(plan.reload.writing_provenance_summary.dig("counts", "unknown")).to eq(13)
    expect(plan.writing_provenance_backfill).to eq("legacy_revision" => 1, "revision" => 2, "finalized_revision" => 2)
  end

  it "attributes repeated prose to its writer rather than an earlier diagram label" do
    source = "```mermaid\nflowchart LR\n A[Foo]\n```\n"
    diagram = CoPlan::Plans::Create.call(title: "Repeated sources", content: source, user: user, actor_type: "local_agent", agent_name: "Claude")
    changed = source + "\n**Foo**\n"
    CoPlan::Plans::ReplaceContent.call(plan: diagram, new_content: changed, base_revision: 1, actor_type: "human", actor_id: user.id,
      input_sources: { "runs" => [ [ changed.length, "human" ] ] })
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu", wait: 20)
    visit plan_page_path(diagram)
    expect(page).to have_css(".mermaid-diagram svg", wait: 20)
    find(".writing-provenance__trigger").click
    click_button "Inspect writing"
    expect(page).to have_button("Done inspecting")
    expect(page.evaluate_script("[...CSS.highlights.get('coplan-writing-human')].map(range => range.toString()).join('')")).to eq("Foo")
    expect(page.evaluate_script("CSS.highlights.get('coplan-writing-ai').size")).to eq(0)
    find("#plan-content-body p strong", text: "Foo", exact_text: true).hover
    expect(page).to have_css('.writing-inspection__tooltip:popover-open', text: user.name)
    expect(find('.writing-inspection__tooltip')).to have_text("Added in v2")
  end

  it "keeps escaped punctuation, entities, and following text in their known source highlight" do
    content = 'Typed \*literal\* &amp; café &copy; &#x1F600; after.'
    escaped = CoPlan::Plans::Create.call(title: "Escaped writing", content: content, user: user, actor_type: "local_agent", agent_name: "Claude")
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu", wait: 20)
    visit plan_page_path(escaped)
    expect(page).to have_text("Typed *literal* & café © 😀 after.")
    find(".writing-provenance__trigger").click
    click_button "Inspect writing"
    expect(page).to have_button("Done inspecting")
    expect(page.evaluate_script("[...CSS.highlights.get('coplan-writing-ai')].map(range => range.toString()).join('').replace(/\\s/g, '')")).to eq("Typed*literal*&café©😀after.")
    expect(page.evaluate_script("CSS.highlights.get('coplan-writing-unknown').size")).to eq(0)
  end

  it "inspects a document made entirely of supported raw HTML" do
    content = '<details><summary>Note</summary>raw <b>HTML</b> &amp; café</details>'
    html = CoPlan::Plans::Create.call(title: "HTML writing", content: content, user: user, actor_type: "local_agent", agent_name: "Claude")
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu", wait: 20)
    visit plan_page_path(html)
    find("#plan-content-body summary", text: "Note").click
    expect(page).to have_text("raw HTML & café")
    find(".writing-provenance__trigger").click
    click_button "Inspect writing"
    expect(page).to have_button("Done inspecting")
    expect(page.evaluate_script("[...CSS.highlights.get('coplan-writing-ai')].map(range => range.toString()).join('').replace(/\\s/g, '')")).to eq("NoterawHTML&café")
    expect(page.evaluate_script("CSS.highlights.get('coplan-writing-unknown').size")).to eq(0)
  end

  it "distinguishes typing from pasted input in embed fields" do
    source = '::: {.iframe src="https://example.com/frame" title="Original" /}'
    embedded = CoPlan::Plans::Create.call(title: "Embed writing", content: source, user: user, actor_type: "local_agent", agent_name: "Claude")
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu", wait: 20)
    visit plan_edit_page_path(embedded)
    expect(page).to have_css('.inline-editor [data-embed-attribute="title"]')
    field = find('[data-embed-attribute="title"]')
    field.send_keys(:end, " humaninput")
    expect(page).to have_text("All changes saved", wait: 20)
    expect(embedded.reload.writing_provenance_summary.fetch("counts").fetch("human")).to be >= 10
    unknown = embedded.writing_provenance_summary.fetch("counts").fetch("unknown")
    page.execute_script(<<~JS, field)
      arguments[0].value += ' pastedunknown';
      arguments[0].dispatchEvent(new InputEvent('input', {inputType:'insertFromPaste', data:' pastedunknown', bubbles:true}));
    JS
    expect(page).to have_text("All changes saved", wait: 20)
    expect(embedded.reload.current_content).to include("pastedunknown")
    expect(embedded.writing_provenance_summary.fetch("counts").fetch("unknown")).to be >= unknown + 13
  end
end
