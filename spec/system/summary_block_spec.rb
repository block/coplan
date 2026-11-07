require "rails_helper"

RSpec.describe "Summary block", type: :system do
  let(:author) { create(:coplan_user, email: "summary-block@example.com") }
  let(:filler) { (1..12).map { |n| "Supporting detail paragraph #{n} that a leader can skip on a first read." }.join("\n\n") }
  let(:content) do
    <<~MD
      # Save latency analysis

      ::: {.summary}
      - **Recommendation:** index plans on the job queue.
      - Saves get about 300 ms faster for long plans.[^profile]
      :::

      ## 1 Background

      #{filler}

      ## 2 Options

      #{filler}

      [^profile]: Measured on staging.
    MD
  end
  let(:plan) do
    CoPlan::Plans::Create.call(title: "Save latency analysis", content: content, user: author,
      visibility: "published", actor_type: "human")
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  it "shows the summary as a labeled card with a pinned outline entry that scrolls to it" do
    visit plan_page_path(plan)

    card = find("#plan-content-body section.plan-summary")
    expect(card).to have_css("li", text: "Recommendation: index plans on the job queue.")
    expect(card).to have_css("sup.footnote-ref a", text: "1")
    expect(page).to have_no_text("::: {.summary}")
    label = page.evaluate_script("getComputedStyle(document.querySelector('section.plan-summary'), '::before').content")
    expect(label).to include("Summary")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('section.plan-summary')).borderLeftStyle")).to eq("solid")

    items = all(".content-nav__list .content-nav__item")
    expect(items.first[:class]).to include("content-nav__item--summary")
    expect(items.first).to have_link("Summary", href: "#plan-summary")

    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")
    expect(page.evaluate_script("document.getElementById('plan-summary').getBoundingClientRect().top")).to be < 0
    find(".content-nav__item--summary a").click
    page.document.synchronize(5) do
      top = page.evaluate_script("document.getElementById('plan-summary').getBoundingClientRect().top")
      raise Capybara::ExpectationNotMet, "summary card is at #{top}px" unless top.between?(0, 200)
    end
    expect(page).to have_css(".content-nav__item--summary .content-nav__link--active")
    expect(page).to have_current_path(/#plan-summary\z/, url: true)
  end

  it "starts a comment from a selection inside the card" do
    visit plan_page_path(plan)

    page.execute_script <<~JS
      const item = document.querySelector('section.plan-summary li');
      const walker = document.createTreeWalker(item, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode()) && !node.textContent.includes('index plans')) {}
      const start = node.textContent.indexOf('index plans');
      const range = document.createRange();
      range.setStart(node, start);
      range.setEnd(node, start + 'index plans on the job queue'.length);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      item.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
    JS
    expect(page).to have_css(".comment-popover", visible: true, wait: 3)
    page.driver.browser.action.send_keys("c").perform

    within("#new-comment-form") do
      textarea = find("textarea:focus")
      textarea.fill_in with: "Which queue?"
      textarea.send_keys(:enter)
    end

    expect(page).to have_css("section.plan-summary mark.anchor-highlight", text: "index plans on the job queue", wait: 5)
    thread = plan.comment_threads.reload.order(:created_at).last
    expect(thread.anchor_text).to eq("index plans on the job queue")
    expect(content[thread.anchor_start...thread.anchor_end]).to eq("index plans on the job queue")
    expect(thread.comments.first.body_markdown).to eq("Which queue?")
  end

  it "keeps the block as one Summary card in the rich editor and saves it unchanged" do
    page.driver.browser.manage.timeouts.script_timeout = 20
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      import("coplan/rich_document").then(m => {
        const examples = [
          "# Plan\n\n::: {.summary}\n- One\n- Two\n:::\n\nBody\n",
          "Intro\n::: {.summary}\nText\n:::\nAfter\n",
          "```markdown\n::: {.summary}\n:::\n```\n",
          "::: {.summary}\nFirst\n:::\n\n::: {.summary}\nSecond\n:::\n",
          "<div>\n::: {.summary}\nExample\n:::\n</div>\n",
          "<!--\n::: {.summary}\nExample\n:::\n-->\n\n::: {.summary}\nReal summary\n:::\n",
          "::: {.summary}\nIntro\n\n<!--\n\n:::\n\n-->\n\nTail\n:::\n"
        ];
        done(examples.map(source => {
          const doc = m.parseDocument(source), kinds = [], summarySources = [];
          doc.forEach(node => {
            kinds.push(node.attrs.kind || node.type.name);
            if (node.attrs.kind === "summary") summarySources.push(node.attrs.source);
          });
          return { summarySources, exact: m.serializeDocument(doc) === source, summaries: kinds.filter(kind => kind === "summary").length };
        }));
      }).catch(error => done({ error: error.message }));
    JS
    expect(result).to all(include("exact" => true))
    expect(result.map { |entry| entry.fetch("summaries") }).to eq([ 1, 1, 0, 1, 0, 1, 1 ])
    expect(result.last.fetch("summarySources").first).to end_with("Tail\n:::\n")

    visit plan_edit_page_path(plan)
    expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
    card = find(".document-editor__block", text: "Summary", match: :first)
    expect(card).to have_css(".document-editor__block-preview section.plan-summary li", text: "Saves get about 300 ms faster", wait: 10)
    expect(card).to have_css(".document-editor__block-preview sup.footnote-ref", text: "1")
    expect(card).to have_no_css("[id='plan-summary']")
    expect(page).to have_no_css(".ProseMirror p", text: "::: {.summary}")

    paragraph = find(".ProseMirror p", text: "Supporting detail paragraph 1 ", match: :first)
    paragraph.click
    paragraph.send_keys(:end, " Reviewed.")
    expect(page).to have_css('[data-coplan--editor-target="statusText"]', text: "All changes saved · v2", visible: :all, wait: 15)
    summary_source = content[/::: \{\.summary\}.*?:::/m]
    expect(plan.reload.current_content).to include(summary_source, "Reviewed.")
    click_button "Done editing"
    expect(page).to have_css("#plan-content-body section.plan-summary", text: "Recommendation:")
    expect(plan.reload.current_content).to include(summary_source)
  end

  it "refreshes citations and renders diagrams inside the summary preview" do
    enriched = content.sub("::: {.summary}", "Earlier citation.[^earlier]\n\n::: {.summary}")
      .sub(":::\n\n## 1 Background", "\n```mermaid\nflowchart LR\nA[Queue] --> B[Search]\n```\n\n:::\n\n## 1 Background")
    enriched += "\n[^earlier]: Earlier reference.\n"
    plan = CoPlan::Plans::Create.call(title: "Save latency analysis", content: enriched, user: author,
      visibility: "published", actor_type: "human")
    visit plan_edit_page_path(plan)
    card = find(".document-editor__block", text: "Summary", match: :first)
    expect(card).to have_css("sup.footnote-ref", text: "2", wait: 15)
    expect(card).to have_css(".mermaid-diagram svg", wait: 20)
    paragraph = find(".ProseMirror p", text: "Earlier citation.")
    page.execute_script(<<~JS, paragraph)
      const range = document.createRange();
      range.selectNodeContents(arguments[0]);
      const selection = window.getSelection();
      selection.removeAllRanges(); selection.addRange(range);
    JS
    page.driver.browser.action.send_keys(:backspace).perform
    expect(card).to have_css("sup.footnote-ref", text: "1", wait: 15)
  end
end
