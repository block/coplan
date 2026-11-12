require "rails_helper"

RSpec.describe "Callouts", type: :system do
  let(:author) { create(:coplan_user, email: "callouts@example.com") }
  let(:source) do
    <<~MD
      # Rollout

      Back up first.

      > [!WARNING]
      > Back up first. The migration cannot be undone.

      > [!tip] Faster path
      > - Use the dry run.
      > - Compare the counts.

      > A plain quote.
    MD
  end
  let(:plan) do
    CoPlan::Plans::Create.call(title: "Callout plan", content: source, user: author,
      visibility: "draft", actor_type: "human")
  end

  before do
    allow(CoPlan::Ai).to receive(:available?).and_return(false)
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  def label_of(selector)
    page.evaluate_script("getComputedStyle(document.querySelector(arguments[0]), '::before').content", selector)
  end

  it "renders each callout with its label and lets a reader comment on text inside it" do
    visit plan_page_path(plan)
    content = find('[data-coplan--text-selection-target="content"]')
    expect(content).to have_css(".callout.callout--warning", text: "The migration cannot be undone.")
    expect(content).to have_css(".callout.callout--tip li", count: 2)
    expect(content).to have_css("blockquote", text: "A plain quote.")
    expect(content).to have_no_text("[!WARNING]")
    expect(content).to have_no_text("[!tip]")
    expect(label_of(".callout--warning")).to eq('"Warning"')
    expect(label_of(".callout--tip")).to eq('"Faster path"')

    page.execute_script <<~JS
      const p = document.querySelector(".callout--warning p");
      const text = p.firstChild;
      const range = document.createRange(); range.setStart(text, 0); range.setEnd(text, "Back up first.".length);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      p.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    JS
    page.driver.browser.action.send_keys("c").perform
    panel = find(".comment-window:popover-open")
    expect(panel).to have_css(".comment-form__quote", text: "Back up first.")
    panel.find("textarea").fill_in with: "Which backup?"
    panel.find("textarea").send_keys(:enter)

    expect(page).to have_css(".callout--warning mark.anchor-highlight", text: "Back up first.", wait: 10)
    thread = plan.comment_threads.reload.last
    expect(thread.anchor_text).to eq("Back up first.")
    expect(thread.anchor_start).to eq(source.index("Back up first.", source.index("[!WARNING]")))
  end

  it "edits a summary as rich content and preserves its marker when saved" do
    source = "# Analysis\n\n> [!SUMMARY] TL;DR\n> What happened."
    document = CoPlan::Plans::Create.call(title: "Analysis", content: source, user: author,
      visibility: "draft", actor_type: "human")
    visit plan_edit_page_path(document)
    expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
    summary = find(".ProseMirror .document-editor__callout--summary")
    expect(summary["data-callout-title"]).to eq("TL;DR")
    summary.find("p").click
    page.driver.browser.action.send_keys(:end, " Why it happened.").perform
    click_button "Raw", exact: true
    expected = source + " Why it happened."
    expect(find('[aria-label="Markdown source"]').text).to eq(expected)
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(document))
    expect(document.reload.current_content).to eq(expected)
    expect(page).to have_css('.callout--summary[data-callout-title="TL;DR"]', text: "Why it happened.")
  end

  it "preserves a table-only callout when a cell is edited and saved" do
    source = "# Findings\n\n> [!SUMMARY]\n>\n> | Finding | State |\n> | --- | --- |\n> | Retry | Ready |"
    document = CoPlan::Plans::Create.call(title: "Findings", content: source, user: author,
      visibility: "draft", actor_type: "human")
    visit plan_edit_page_path(document)
    expect(page).to have_css(".ProseMirror .document-editor__callout--summary table", text: "Ready")
    click_button "Edit table"
    field = find('[aria-label="Table Markdown"]')
    field.fill_in with: field.value.sub("Ready", "Done")
    click_button "Raw", exact: true
    expect(find('[aria-label="Markdown source"]').text).to include("> [!SUMMARY]", "> | Retry | Done |")
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(document))
    expect(document.reload.current_content).to include("> [!SUMMARY]", "> | Retry | Done |")
    expect(page).to have_css(".callout--summary table", text: "Done")
  end

  it "preserves math inside a callout through a rich edit and save" do
    content = "# Retry budget\n\n> [!TIP] Estimate\n> Use $p^n$ for retries."
    document = CoPlan::Plans::Create.call(title: "Retry budget", content: content, user: author,
      visibility: "draft", actor_type: "human")
    visit plan_page_path(document)
    expect(page).to have_css(".callout--tip .katex")
    visit plan_edit_page_path(document)
    expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
    callout = find(".ProseMirror .document-editor__callout--tip")
    expect(callout).to have_css(".document-editor__math", text: "$p^n$")
    callout.find("p").click
    page.driver.browser.action.send_keys(:end, " Check the estimate.").perform
    click_button "Raw", exact: true
    expected = content + " Check the estimate."
    expect(find('[aria-label="Markdown source"]').text).to eq(expected)
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(document))
    expect(document.reload.current_content).to eq(expected)
    expect(page).to have_css(".callout--tip .katex")
    expect(page).to have_css(".callout--tip", text: "Check the estimate.")
  end

  it "keeps callouts readable in either deck theme regardless of app mode" do
    content = %w[coplan graphite].map do |theme|
      "::: {.presentation theme=\"#{theme}\"}\n\n# Callout slide\n\n> [!TIP]\n> Readable in either app mode.\n\n:::\n"
    end.join("\n")
    deck = CoPlan::Plans::Create.call(title: "Callout decks", content: content, user: author,
      visibility: "draft", actor_type: "human")
    visit plan_page_path(deck)
    expect(page).to have_css(".deck .callout", count: 2)
    palettes = %w[light dark].map do |mode|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", mode)
      page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll(".deck .callout"), node => {
          const style = getComputedStyle(node), slide = getComputedStyle(node.closest(".deck-slide"));
          return { text: style.color, ink: slide.color, label: getComputedStyle(node, "::before").color,
                   border: style.borderLeftColor, background: style.backgroundColor };
        })
      JS
    end
    palettes.flatten.each { |palette| expect(palette["text"]).to eq(palette["ink"]) }
    expect(palettes.first).to eq(palettes.last)
  end

  it "keeps literal markers and empty-callout boundaries consistent with the reader", :aggregate_failures do
    samples = [
      "> \\[!NOTE]\n> Literal.\n",
      "> [!UNKNOWN]\n> Literal.\n",
      ">\n> [!NOTE]\n> Literal.\n",
      "> [!NOTE]\nOutside the callout.\n",
      ">[!NOTE]\n> Literal.\n",
      ">  [!NOTE]\n> Literal.\n",
      ">\t[!NOTE]\n> Literal.\n",
      "> [!NOTE]\n> a\n> ---\n",
      "> [!NOTE]\n> ---\n",
      "> [!NOTE]\n> ===\n"
    ]
    results = page.evaluate_async_script(<<~'JS', samples)
      const sources = arguments[0], done = arguments[1];
      import("coplan/rich_document").then(m => done(sources.map(source => {
        const doc = m.parseDocument(source), callouts = [];
        doc.descendants(node => { if (node.attrs.callout) callouts.push(node.textContent); });
        const rebuilt = doc.type.create(null, doc.content.content.map(node => node.type.name === "preserved" ? node :
          node.type.create({ ...node.attrs, source: null, snapshot: null }, node.content, node.marks)));
        return { callouts, roundtrip: m.serializeDocument(doc), rewritten: m.serializeDocument(rebuilt) };
      }))).catch(error => done({ error: error.message }));
    JS
    expect(results.map { |result| result["callouts"] }).to all(eq([]))
    expect(results.map { |result| result["roundtrip"] }).to eq(samples)
    results[4..6].each do |result|
      html = ApplicationController.helpers.render_markdown(result["rewritten"])
      expect(Nokogiri::HTML.fragment(html).at_css(".callout")).to be_nil
    end
    expect(results.last(3).map { |result| result["rewritten"] }).to eq(samples.last(3))
  end

  it "preserves a setext callout while saving an edit to nearby prose" do
    source = "# Setext callout\n\n> [!NOTE]\n> Heading body\n> ---\n\nAfter."
    document = CoPlan::Plans::Create.call(title: "Setext callout", content: source, user: author,
      visibility: "draft", actor_type: "human")
    visit plan_edit_page_path(document)
    expect(page).to have_css(".document-editor__block-preview .callout h2", text: "Heading body")
    paragraph = find(".ProseMirror p", text: "After.", exact_text: true)
    paragraph.click
    paragraph.send_keys(:end, " Edited.")
    click_button "Raw", exact: true
    expected = source.sub("After.", "After. Edited.")
    expect(find('[aria-label="Markdown source"]').text).to eq(expected.strip)
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(document))
    expect(document.reload.current_content).to eq(expected)
    expect(page).to have_css(".callout h2", text: "Heading body")
  end

  it "keeps each marker unchanged through the rich editor" do
    round_trips = page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      import("coplan/rich_document").then(m => {
        const sources = [
          "> [!NOTE]\n> Plain body.\n", "> [!TIP]\n> Tip.\n", "> [!IMPORTANT]\n> Important.\n",
          "> [!WARNING]\n> Warning.\n", "> [!CAUTION]\n> Caution.\n", "> [!note] Custom title\n> Body.\n",
          "> [!NOTE]\n>\n> After a blank line.\n", "> [!NOTE]\n> - one\n> - two\n", "> [!NOTE]\n",
          "> [!FOO]\n> Not a callout.\n", "> Plain quote.\n", "- Item\n\n  > [!TIP]\n  > Nested.\n",
          "> [!SUMMARY]\n> Summary.\n", "- > [!SUMMARY]\n  > Nested summary.\n"
        ];
        done(sources.map(source => {
          const doc = m.parseDocument(source);
          const quotes = [];
          doc.descendants(node => { if (node.type.name === "blockquote") quotes.push(node.attrs.callout); });
          // Rebuild every block so the serializer, not the saved source, writes it.
          const fresh = doc.type.create(null, doc.content.content.map(node =>
            node.type.create({ ...node.attrs, source: null, snapshot: null }, node.content, node.marks)));
          return { source, exact: m.serializeDocument(doc) === source, rewritten: m.serializeDocument(fresh), callouts: quotes };
        }));
      }).catch(error => done({ error: error.message }));
    JS
    expect(round_trips).to all(include("exact" => true))
    expect(round_trips.map { |entry| entry["callouts"] }).to eq([
      [ "note" ], [ "tip" ], [ "important" ], [ "warning" ], [ "caution" ], [ "note" ],
      [ "note" ], [ "note" ], [ "note" ], [ nil ], [ nil ], [ "tip" ], [ "summary" ], [ "summary" ]
    ])
    round_trips.first(6).each do |entry|
      expect(entry["rewritten"].strip).to eq(entry["source"].strip)
    end
    expect(round_trips[6]["rewritten"]).to start_with("> [!NOTE]\n> After a blank line.")
    expect(round_trips[7]["rewritten"]).to start_with("> [!NOTE]\n> * one\n> * two")
    expect(round_trips[8]["rewritten"].strip).to eq("> [!NOTE]")
    expect(round_trips[-2]["rewritten"].strip).to eq(round_trips[-2]["source"].strip)
    expect(round_trips.last["rewritten"]).to include("[!SUMMARY]", "Nested summary.")

    visit plan_edit_page_path(plan)
    expect(page).to have_css('.ProseMirror[contenteditable="true"]', wait: 20)
    expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
    callout = find(".ProseMirror blockquote.document-editor__callout--warning")
    expect(callout).to have_text("Back up first. The migration cannot be undone.", exact: true)
    expect(page).to have_css(".ProseMirror blockquote.document-editor__callout--tip[data-callout-title='Faster path']")
    expect(label_of(".document-editor__callout--warning")).to eq('"Warning"')

    callout.find("p").click
    page.driver.browser.action.send_keys(:end, " Take a snapshot.").perform
    expect(callout).to have_text("cannot be undone. Take a snapshot.")
    click_button "Raw", exact: true
    expected = source.sub("cannot be undone.", "cannot be undone. Take a snapshot.")
    expect(page).to have_css('[aria-label="Markdown source"]', text: "> [!WARNING]")
    expect(find('[aria-label="Markdown source"]').text).to eq(expected.strip)
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan))
    expect(plan.reload.current_content).to eq(expected)
    expect(page).to have_css(".callout--warning", text: "Take a snapshot.")
  end
end
