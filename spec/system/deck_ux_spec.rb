require "rails_helper"

# Browser-level coverage for the deck's pointer and navigation behavior:
# the show filling the window rather than taking the screen (a call shares
# windows), the two ways a presenter marks up a live slide (selecting text,
# and the pen), the Mermaid expand chip staying chip-sized on a slide, and
# the back-matter links jumping in place instead of refetching the page.
RSpec.describe "Deck UX", type: :system do
  let(:user) { create(:coplan_user, email: "presenter@example.com") }
  let(:deck_type) { create(:plan_type, name: "Deck UX Presentation") }

  let(:deck_content) do
    <<~MARKDOWN
      # Shared workspaces

      Every slide earns its layout from its shape alone.

      ---

      ## What the classifier sees

      - A lone heading becomes a title slide
      - One image or diagram takes the whole stage

      ---

      ## How a slide finds its shape

      ```mermaid
      flowchart LR
        markdown --> Split
        Split --> Classify
      ```

      ---

      ## Before the readout

      - [ ] Confirm the fit report is clean
      - [ ] Send the deck round
    MARKDOWN
  end

  let(:plan) do
    p = create(:plan, :published, created_by_user: user, plan_type: deck_type, title: "Readout deck")
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 2,
      content_markdown: "::: {.presentation}\n\n#{deck_content}\n:::", actor_type: "human", actor_id: user.id
    )
    p.update!(current_plan_version: version, current_revision: 2)
    p
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
  end

  # Sweeps a real selection across an element the way a presenter drags a
  # line: mouse down inside it, move, release. Selenium's action chain is
  # what makes this a genuine drag — a scripted Range wouldn't exercise the
  # click the browser synthesizes at the end of one.
  def drag_across(selector)
    element = find(selector, match: :first).native
    width = element.rect.width.to_i
    page.driver.browser.action
        .move_to(element, -(width / 2) + 2, 0)
        .click_and_hold
        .move_to(element, (width / 2) - 2, 0)
        .release
        .perform
  end

  def current_slide
    page.evaluate_script(
      %{document.querySelector(".deck-slide--current")?.dataset.slide}
    )
  end

  it "disables slide steps at each deck boundary" do
    visit plan_page_path(plan)

    expect(page).to have_css(".deck-toolbar__step--previous:disabled")
    expect(page).to have_css(".deck-toolbar__step--next:not(:disabled)")
    3.times { find(".deck-toolbar__step--next").click }

    expect(page).to have_css(".deck-toolbar__count[data-count='4 / 4']")
    expect(page).to have_css(".deck-toolbar__step--next:disabled")
    expect(page).to have_css(".deck-toolbar__step--previous:not(:disabled)")
  end

  it "reads and presents each embedded deck independently" do
    mixed = <<~MD
      Introductory context.

      ::: {.presentation}

      # First deck, one

      ---

      # First deck, two

      :::

      Between the proposals.

      ::: {.presentation}

      # Second deck, one

      ---

      # Second deck, two

      :::

      Closing analysis.
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: mixed,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)

    expect(page).to have_css(".deck-region", count: 2)
    first_deck, second_deck = all(".deck-region")
    first_deck.find(".deck-toolbar__step--next").click
    expect(first_deck.find(".deck-toolbar__count")["data-count"]).to eq("2 / 2")
    expect(second_deck.find(".deck-toolbar__count")["data-count"]).to eq("1 / 2")
    second_deck.find(".deck-toolbar__present").click
    expect(second_deck).to have_css(".deck--presenting .deck-slide--current[data-slide='1']")
    send_keys(:escape)
    expect(second_deck).to have_css(".deck-slide--current[data-slide='1']", visible: true)
    second_deck.click
    send_keys(:arrow_right)
    expect(second_deck.find(".deck-toolbar__count")["data-count"]).to eq("2 / 2")
    expect(first_deck.find(".deck-toolbar__count")["data-count"]).to eq("2 / 2")
    send_keys("p")
    expect(second_deck).to have_css(".deck--presenting .deck-slide--current[data-slide='2']")
    send_keys(:escape)
  end

  it "keeps the reader's slide when live content replaces the document" do
    visit plan_page_path(plan)
    find(".deck-toolbar__step--next").click
    expect(page).to have_css(".deck-toolbar__count[data-count='2 / 4']")

    page.execute_script(<<~JS)
      const target = document.getElementById("plan-content-body")
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "coplan-replace-if-clean")
      stream.setAttribute("target", "plan-content-body")
      stream.setAttribute("data-revision", "#{plan.current_revision + 1}")
      const template = document.createElement("template")
      template.innerHTML = target.innerHTML
      stream.append(template)
      document.body.append(stream)
    JS

    expect(page).to have_css(".deck-toolbar__count[data-count='2 / 4']")
    expect(page).to have_css(".deck-slide--current[data-slide='2']", visible: true)
  end

  def queue_section_edits(revisions:, rewritten: false)
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      fetch("#{content_body_plan_path(plan)}", { headers: { Accept: "text/html" } })
        .then(response => response.text())
        .then(html => {
          for (const revision of #{revisions.to_json}) {
            const keys = #{rewritten} && revision === 3 ? [] :
              (revision === 3 ? ['what-the-classifier-sees'] : ['before-the-readout'])
            const stream = document.createElement('turbo-stream')
            stream.setAttribute('action', 'coplan-replace-if-clean')
            stream.setAttribute('target', 'plan-content-body')
            stream.setAttribute('data-revision', revision)
            stream.setAttribute('data-changed-sections', JSON.stringify({keys}))
            stream.setAttribute('data-section-update', JSON.stringify({
              by: revision === 3 ? 'First editor' : 'Second editor', at: new Date().toISOString(),
              ago: 'just now', revision, keys, rewritten: #{rewritten} && revision === 3
            }))
            const template = document.createElement('template')
            template.innerHTML = html.replaceAll('A lone heading becomes a title slide', 'Title slide from the first editor')
            if (revision === 4) template.innerHTML = template.innerHTML.replaceAll('Send the deck round', 'Checklist from the second editor')
            stream.append(template)
            document.body.append(stream)
          }
          done(true)
        })
    JS
    expect(page).to have_no_css('turbo-stream[action="coplan-replace-if-clean"]', visible: :all)
    expect(page.evaluate_script("document.getElementById('plan-content-body').__pendingDeckUpdate?.incomingRevision")).to eq(4)
  end

  [ [ 3, 4 ], [ 4, 3 ] ].each do |revisions|
    it "keeps queued changes and their editors when revisions arrive as #{revisions.join(', ')} during a show" do
      visit plan_page_path(plan)
      start_show
      queue_section_edits(revisions: revisions)
      expect(page).to have_css(".deck--presenting")
      expect(page).to have_no_text("Checklist from the second editor")

      send_keys(:escape)

      expect(page).to have_no_css(".deck--presenting")
      expect(page).to have_css(".changed-sections-note", text: "2 sections updated")
      expect(page).to have_css('#what-the-classifier-sees .section-update-marker[aria-label*="First editor"]', visible: :all)
      expect(page).to have_css('#before-the-readout .section-update-marker[aria-label*="Second editor"]', visible: :all)
      find(".deck-toolbar__step--next").click
      find('#what-the-classifier-sees .section-update-marker').hover
      expect(page).to have_css('.deck-slide--current', text: "Title slide from the first editor")
      2.times { find(".deck-toolbar__step--next").click }
      find('#before-the-readout .section-update-marker').hover
      expect(page).to have_css('.deck-slide--current', text: "Checklist from the second editor")
      expect(page.evaluate_script("document.getElementById('plan-content-body').getAttribute('data-coplan--live-update-revision-value')")).to eq("4")
    end
  end

  it "keeps an extensive-update notice queued before a later minor edit during a show" do
    visit plan_page_path(plan)
    start_show
    queue_section_edits(revisions: [ 3, 4 ], rewritten: true)

    send_keys(:escape)

    expect(page).to have_no_css(".deck--presenting")
    expect(page).to have_css(".changed-sections-note", text: "Updated throughout since your last visit.")
    expect(page).to have_no_css(".section-update-marker", visible: :all)
  end

  it "keeps slide positions with their decks when id-less decks reorder" do
    mixed = <<~MD
      ::: {.presentation}

      # Alpha one

      ---

      # Alpha two

      :::

      ::: {.presentation}

      # Beta one

      ---

      # Beta two

      :::
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: mixed,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)
    all(".deck-region").first.find(".deck-toolbar__step--next").click
    expect(all(".deck-region").first).to have_css(".deck-toolbar__count[data-count='2 / 2']")

    page.execute_script(<<~JS)
      const target = document.getElementById("plan-content-body")
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "coplan-replace-if-clean")
      stream.setAttribute("target", "plan-content-body")
      stream.setAttribute("data-revision", "#{plan.current_revision + 1}")
      const template = document.createElement("template")
      template.innerHTML = target.innerHTML
      const decks = template.content.querySelectorAll(".deck-region")
      decks[0].before(decks[1])
      stream.append(template)
      document.body.append(stream)
    JS

    Selenium::WebDriver::Wait.new(timeout: 5).until do
      page.evaluate_script(<<~JS)
        (() => {
          const [first, second] = document.querySelectorAll(".deck-region")
          return first?.querySelector(".deck-slide--current")?.textContent.includes("Beta one") &&
            second?.querySelector(".deck-slide--current")?.textContent.includes("Alpha two")
        })()
      JS
    end
  end

  it "starts a replacement id-less deck on its first slide" do
    mixed = <<~MD
      ::: {.presentation}

      # Alpha one

      ---

      # Alpha two

      ---

      # Alpha three

      :::

      ::: {.presentation}

      # Beta one

      ---

      # Beta two

      :::
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: mixed,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)
    2.times { all(".deck-region").first.find(".deck-toolbar__step--next").click }
    expect(all(".deck-region").first).to have_css(".deck-toolbar__count[data-count='3 / 3']")

    page.execute_script(<<~JS)
      const target = document.getElementById("plan-content-body")
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "coplan-replace-if-clean")
      stream.setAttribute("target", "plan-content-body")
      stream.setAttribute("data-revision", "#{plan.current_revision + 1}")
      const template = document.createElement("template")
      template.innerHTML = target.innerHTML
      const replacement = template.content.querySelector(".deck-region")
      replacement.dataset.deckSourceDigest = "replacement-deck"
      replacement.querySelectorAll(".deck-slide h1").forEach((heading, index) => {
        heading.textContent = `Gamma ${index + 1}`
      })
      stream.append(template)
      document.body.append(stream)
    JS

    expect(page).to have_css(".deck-region .deck-toolbar__count[data-count='1 / 3']")
    expect(page).to have_css(".deck-region .deck-slide--current", text: "Gamma 1")
    expect(page).to have_css(".deck-region .deck-toolbar__count[data-count='1 / 2']")
  end

  it "keeps a heading-free deck position after its DOM changes" do
    content = <<~MD
      ::: {.presentation}

      First narrative.

      ---

      ```mermaid
      flowchart LR
        A --> B
      ```

      :::
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)
    find(".deck-toolbar__step--next").click
    expect(page).to have_css(".deck-toolbar__count[data-count='2 / 2']")
    page.execute_script('document.querySelector(".deck-slide--current .markdown-rendered").innerHTML = "<div>Rendered diagram</div>"')

    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      fetch("#{content_body_plan_path(plan)}", { headers: { Accept: "text/html" } })
        .then(response => response.text())
        .then(html => {
          const stream = document.createElement("turbo-stream")
          stream.setAttribute("action", "coplan-replace-if-clean")
          stream.setAttribute("target", "plan-content-body")
          stream.setAttribute("data-revision", "#{plan.current_revision + 1}")
          const template = document.createElement("template")
          template.innerHTML = html
          stream.append(template)
          document.body.append(stream)
          done(true)
        })
    JS

    expect(page).to have_css(".deck-toolbar__count[data-count='2 / 2']")
    expect(page).to have_css(".deck-slide--current[data-slide='2']", visible: true)
  end

  it "keeps a heading-free deck position when its source changes" do
    content = <<~MD
      ::: {.presentation}

      First narrative.

      ---

      Second narrative.

      :::
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)
    find(".deck-toolbar__step--next").click
    expect(page).to have_css(".deck-toolbar__count[data-count='2 / 2']")

    page.execute_script(<<~JS)
      const target = document.getElementById("plan-content-body")
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "coplan-replace-if-clean")
      stream.setAttribute("target", "plan-content-body")
      stream.setAttribute("data-revision", "#{plan.current_revision + 1}")
      const template = document.createElement("template")
      template.innerHTML = target.innerHTML
      const deck = template.content.querySelector(".deck-region")
      deck.dataset.deckSourceDigest = "edited-source-digest"
      deck.querySelector(".deck-slide:last-child").innerHTML = "<p>Edited second narrative.</p>"
      stream.append(template)
      document.body.append(stream)
    JS

    expect(page).to have_css(".deck-slide--current[data-slide='2']", visible: true, text: "Edited second narrative.")
    expect(page).to have_css(".deck-toolbar__count[data-count='2 / 2']")
  end

  it "keeps an explicitly named deck position when its source changes" do
    content = <<~MD
      ::: {.presentation #proposal}

      # First slide

      ---

      # Second slide

      :::
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)
    find(".deck-toolbar__step--next").click

    page.execute_script(<<~JS)
      const target = document.getElementById("plan-content-body")
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "coplan-replace-if-clean")
      stream.setAttribute("target", "plan-content-body")
      stream.setAttribute("data-revision", "#{plan.current_revision + 1}")
      const template = document.createElement("template")
      template.innerHTML = target.innerHTML
      const deck = template.content.querySelector(".deck-region")
      deck.dataset.deckSourceDigest = "edited-source-digest"
      deck.querySelector(".deck-slide:last-child h1").textContent = "Revised second slide"
      stream.append(template)
      document.body.append(stream)
    JS

    expect(page).to have_css(".deck-region[data-deck-region-id='proposal'] .deck-slide--current[data-slide='2']", text: "Revised second slide")
  end

  it "marks a changed heading nested in a split slide" do
    content = <<~MD
      ::: {.presentation}

      Opening words.

      ## Results

      Analysis body.

      ![board](board.png)

      :::
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)
    expect(page).to have_css(".deck-slide--split .deck-body h2", text: "Results")
    page.execute_script(<<~JS)
      const layout = document.querySelector(".plan-layout")
      layout.setAttribute("data-coplan--changed-sections-keys-value", '["results"]')
      window.Stimulus.getControllerForElementAndIdentifier(layout, "coplan--changed-sections").connect()
    JS

    expect(page).to have_css(".deck-body h2.section-updated", text: "Results")
    expect(page).to have_no_css(".deck-body p.section-updated")
    expect(page).to have_css(".deck-slide--current h2.section-updated--viewed", text: "Results", wait: 5)
  end

  it "keeps the reader's slide when the inline editor closes" do
    visit plan_page_path(plan)
    2.times { find(".deck-toolbar__step--next").click }
    expect(page).to have_css(".deck-toolbar__count[data-count='3 / 4']")

    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    find(".inline-editor").click_button "Done editing"

    expect(page).to have_no_css(".inline-editor form.document-editor", wait: 10)
    expect(page).to have_css(".deck-toolbar__count[data-count='3 / 4']")
    expect(page).to have_css(".deck-slide--current[data-slide='3']", visible: true)
  end

  it "ignores the presentation shortcut while the inline editor hides the reader" do
    visit plan_page_path(plan)
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
    find(".inline-editor button[aria-label='Done editing']").send_keys("p")

    expect(page).to have_no_css(".deck--presenting", visible: :all)
    expect(page.evaluate_script("window.location.hash")).not_to match(/^#present-/)
    expect(page.evaluate_script("document.documentElement.style.overflow")).not_to eq("hidden")
  end

  it "reveals a hidden slide when its heading is selected in the outline" do
    visit plan_page_path(plan)

    expect(page).to have_css(".deck-region .deck-slide--current[data-slide='1']")
    find(".content-nav__link", text: "How a slide finds its shape").click

    expect(page).to have_css(".deck-region .deck-slide--current[data-slide='3']")
    expect(find(".deck-toolbar__count")["data-count"]).to eq("3 / 4")
  end

  it "reveals a hidden slide targeted by a direct link" do
    content = ("Long introduction.\n\n" * 40) + "::: {.presentation}\n\n#{deck_content}\n:::"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit "#{plan_page_path(plan)}#how-a-slide-finds-its-shape"

    expect(page).to have_css(".deck-region .deck-slide--current[data-slide='3']")
    Selenium::WebDriver::Wait.new(timeout: 5).until do
      page.evaluate_script(<<~JS)
        (() => {
          const top = document.getElementById("how-a-slide-finds-its-shape").getBoundingClientRect().top
          return top >= -20 && top < window.innerHeight
        })()
      JS
    end
  end

  it "clears an old heading fragment after presenting another slide" do
    visit "#{plan_page_path(plan)}#how-a-slide-finds-its-shape"
    expect(page).to have_css(".deck-slide--current[data-slide='3']")

    find(".deck-toolbar__present").click
    send_keys(:arrow_right)
    expect(page).to have_css(".deck--presenting .deck-slide--current[data-slide='4']")
    send_keys(:escape)

    expect(page).to have_css(".deck-slide--current[data-slide='4']", visible: true)
    expect(page.evaluate_script("window.location.hash")).to eq("")
  end

  it "starts the deck named in a presentation resume URL" do
    content = <<~MD
      ::: {.presentation}

      # First deck

      :::

      ::: {.presentation}

      # Second deck, one

      ---

      # Second deck, two

      :::
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit "#{plan_page_path(plan)}#present-2-2"
    send_keys("p")

    expect(all(".deck-region").last).to have_css(".deck--presenting .deck-slide--current[data-slide='2']")
    send_keys(:escape)
  end

  it "tracks the visible slide in the outline" do
    visit plan_page_path(plan)
    find(".deck-toolbar__step--next").click

    expect(page).to have_css(".deck-slide--current[data-slide='2']")
    expect(page).to have_css(".content-nav__item[data-heading-id='what-the-classifier-sees'] .content-nav__link--active")
    expect(page).not_to have_css(".content-nav__item[data-heading-id='before-the-readout'] .content-nav__link--active")
  end

  it "reveals a hidden slide before opening its structural comment" do
    visit plan_page_path(plan)
    page.execute_script(<<~JS)
      const slide = document.querySelector('.deck-slide[data-slide="3"]')
      const badge = document.createElement("mark")
      badge.className = "anchor-highlight anchor-highlight--open"
      badge.dataset.threadId = "structural-thread"
      badge.setAttribute("data-source-badge", "")
      badge.addEventListener("coplan:source-thread", event => {
        window.__sourceDispatched = true
        event.stopPropagation()
      })
      slide.append(badge)
      const thread = document.createElement("div")
      thread.id = "structural-thread"
      thread.dataset.threadId = "structural-thread"
      document.body.append(thread)
      const nav = document.querySelector('[data-controller~="coplan--comment-nav"]')
      window.Stimulus.getControllerForElementAndIdentifier(nav, "coplan--comment-nav").navigateTo(badge)
    JS

    expect(page).to have_css(".deck-slide--current[data-slide='3']")
    expect(page.evaluate_script("window.__sourceDispatched")).to eq(true)
  end

  it "reveals a hidden slide for a structural discussion deep link" do
    content = <<~MD
      ::: {.presentation}

      # Opening

      ---

      # Table

      | Decision |
      | -------- |
      | Review   |

      :::
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    html = Commonmarker.to_html(content, options: { render: { sourcepos: true } }, plugins: { syntax_highlighter: nil })
    mapped = CoPlan::Plans::SourceTargets.new(content).annotate(Nokogiri::HTML.fragment(html))
    cell = mapped.css("[data-source-target]").find { |node| node.text.include?("Review") }
    token = JSON.parse(cell["data-source-target"])["token"]
    thread = create(:comment_thread, plan: plan, created_by_user: user, source_token: token)
    thread.comments.create!(author_type: "human", author_id: user.id, body_markdown: "Review this cell")

    visit "#{plan_page_path(plan)}?thread=#{thread.id}"

    expect(page).to have_css(".deck-slide--current[data-slide='2']")
    expect(page).to have_css(".source-comments:popover-open", text: "Review this cell")
  end

  it "marks changes in a later content region" do
    content = <<~MD
      # Opening

      Unchanged introduction.

      ::: {.presentation}

      # First slide

      Unchanged slide.

      :::

      # Closing

      Fresh closing text.
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)
    page.execute_script(<<~JS)
      const layout = document.querySelector(".plan-layout")
      layout.setAttribute("data-coplan--changed-sections-keys-value", '["closing"]')
      const controller = window.Stimulus?.getControllerForElementAndIdentifier(layout, "coplan--changed-sections")
      controller?.connect()
    JS
    expect(page).to have_css(".markdown-rendered h1.section-updated", text: "Closing")
  end

  it "keeps update markers out of discussion bodies" do
    content = "# Closing\n\nFresh closing text."
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    thread = create(:comment_thread, plan: plan, created_by_user: user)
    create(:comment, comment_thread: thread, author_id: user.id, body_markdown: "Unchanged discussion text.")
    visit plan_page_path(plan)
    page.execute_script(<<~JS)
      const layout = document.querySelector(".plan-layout")
      layout.setAttribute("data-coplan--changed-sections-keys-value", '["closing"]')
      window.Stimulus.getControllerForElementAndIdentifier(layout, "coplan--changed-sections").connect()
    JS

    expect(page).to have_css("#plan-content-body h1.section-updated", text: "Closing")
    expect(page).to have_no_css("#plan-threads .section-updated", visible: :all)
  end

  it "flashes a live change in a later content region" do
    content = <<~MD
      # Opening

      Unchanged introduction.

      ::: {.presentation}

      # Slide

      Unchanged slide.

      :::

      # Closing

      Old closing text.
    MD
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
    visit plan_page_path(plan)
    page.execute_script(<<~JS)
      const target = document.getElementById("plan-content-body")
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "coplan-replace-if-clean")
      stream.setAttribute("target", "plan-content-body")
      stream.setAttribute("data-revision", "#{plan.current_revision + 1}")
      stream.setAttribute("data-changed-sections", JSON.stringify({keys: ["closing"]}))
      const template = document.createElement("template")
      template.innerHTML = target.innerHTML.replace("Old closing text.", "New closing text.")
      stream.append(template)
      document.body.append(stream)
    JS

    expect(page).to have_css(".markdown-rendered .agent-flash-block, .markdown-rendered .agent-flash", text: /New closing text\.|New/)
  end

  it "opens help above a presentation without navigating the slide behind it" do
    visit plan_page_path(plan)
    start_show
    first_slide = current_slide
    page.driver.browser.action.send_keys("?").perform
    expect(page).to have_css(".keyboard-shortcuts[open]")
    page.driver.browser.action.send_keys(:arrow_right).perform
    expect(current_slide).to eq(first_slide)
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).not_to have_css(".keyboard-shortcuts[open]")
    expect(page).to have_css(".deck--presenting")
    page.driver.browser.action.send_keys(:arrow_right).perform
    expect(current_slide).not_to eq(first_slide)
  end

  # Strokes are ephemeral by design, so counting them after the fact is a
  # race with their own fade. Watch the canvas instead and count every
  # stroke that was ever added to it.
  def watch_strokes
    page.execute_script(<<~JS)
      window.__strokes = 0;
      new MutationObserver(records => records.forEach(record => {
        record.addedNodes.forEach(node => {
          if (node.classList?.contains("deck-ink__stroke")) window.__strokes++;
        });
      })).observe(document.querySelector(".deck"), { childList: true, subtree: true });
    JS
  end

  def strokes_drawn
    page.evaluate_script("window.__strokes")
  end

  # Wait for the deck itself before reaching for the button. This page
  # renders Mermaid, so it settles well past Capybara's 2s default on a
  # loaded CI runner — and the toolbar only exists once the deck does, so
  # a bare click_button spends that whole default budget looking for a
  # button the server hasn't sent yet. (The examples below that don't
  # present already wait explicitly for the same reason.)
  def start_show
    expect(page).to have_css(".deck-slide", wait: 10)
    find(".deck-toolbar__present").click
    expect(page).to have_css(".deck--presenting .deck-slide--current", wait: 5)
  end

  def attachments_on_screen?
    page.evaluate_script(<<~JS)
      (() => {
        const box = document.getElementById("footnote-attachments").getBoundingClientRect();
        return box.top < window.innerHeight && box.bottom > 0;
      })()
    JS
  end

  it "keeps the title-slide accent above its aligned section shortcut" do
    visit plan_page_path(plan)
    expect(page).to have_css(".deck-slide--title .section-permalink", visible: :all)

    layout = page.evaluate_script(<<~JS)
      (() => {
        const heading = document.querySelector(".deck-slide--title .section-heading")
        const title = heading.querySelector(".section-heading__title").getBoundingClientRect()
        const link = heading.querySelector(".section-permalink").getBoundingClientRect()
        const accent = getComputedStyle(heading, "::before")
        return {
          display: getComputedStyle(heading).display,
          accentColumn: `${accent.gridColumnStart} / ${accent.gridColumnEnd}`,
          centerDelta: Math.abs((title.top + title.bottom - link.top - link.bottom) / 2)
        }
      })()
    JS

    expect(layout).to include("display" => "grid", "accentColumn" => "1 / -1")
    expect(layout["centerDelta"]).to be < 1
  end

  describe "present mode" do
    it "treats a drag as a highlight and a bare click as the next slide" do
      visit plan_page_path(plan)
      start_show
      expect(current_slide).to eq("1")

      # Advance to a slide with body text to sweep.
      find(".deck-slide--current").click
      expect(current_slide).to eq("2")

      drag_across(".deck-slide--current li")

      # The selection is the point being made — the show must not have moved
      # out from under it, and no comment affordance may cover the slide.
      expect(current_slide).to eq("2")
      expect(page.evaluate_script("document.getSelection().toString()"))
        .to include("A lone heading becomes a title slide")
      expect(page).to have_css(".comment-popover", visible: :hidden)

      # A bare click aimed at the presenter's own highlight still advances,
      # and leaves the mark behind with the slide.
      find(".deck-slide--current li", match: :first).click
      expect(current_slide).to eq("3")
      expect(page.evaluate_script("document.getSelection().toString()")).to eq("")
    end

    it "still hands a focused control its keys after the mouse has been used" do
      visit plan_page_path(plan)
      start_show

      # Three mouse clicks to reach the task slide — each one leaves a
      # pointer origin behind, which is the whole point of the setup.
      3.times { find(".deck-slide--current").click }
      expect(current_slide).to eq("4")

      checkbox = find(".deck-slide--current input[type='checkbox']", match: :first)
      checkbox.execute_script("this.focus()")

      # Space on a focused checkbox is the presenter ticking a box mid-show.
      # The click the browser synthesizes for it carries no coordinates, so
      # measuring it against the last mouse position read as a drag: the
      # click was swallowed and the box silently did not move.
      send_keys(:space)
      expect(checkbox).to be_checked
    end

    # A call shares a window; macOS moves a fullscreen window onto its own
    # Space, where screen-share pickers can't see it. So starting the show
    # must not take the screen — `f` is the presenter asking for it.
    #
    # Reached by its readable address rather than plan_path's /_/plans/<id>.
    # That's the canonical URL — PlansController 301s the id form onto it —
    # so it's the address a presenter actually opens. It also steps around
    # a CI-only routing failure on the legacy id path that this example
    # kept tripping (see the note on the issue filed alongside this).
    it "fills the window without taking the screen, and takes it on f" do
      visit "/#{plan.url_path}"
      start_show
      expect(page.evaluate_script("!!document.fullscreenElement")).to be(false)

      # The window is the canvas either way: the deck is in the top layer,
      # so no glass card ancestor can trap or cover it.
      expect(page.evaluate_script(<<~JS)).to be(true)
        (() => {
          const deck = document.querySelector(".deck--presenting");
          if (!deck.matches(":popover-open")) return false;
          const box = deck.getBoundingClientRect();
          const fits = Math.min(window.innerWidth, window.innerHeight * 16 / 9);
          return Math.abs(box.width - fits) < 2;
        })()
      JS

      send_keys("f")
      expect(page).to have_css(".deck-presenter:fullscreen", wait: 5)

      # Escape gives the screen back and the show carries on in the window —
      # full screen is a layer to peel, not the show itself.
      send_keys(:escape)
      expect(page).to have_no_css(".deck-presenter:fullscreen", wait: 5)
      expect(page).to have_css(".deck--presenting")
      expect(current_slide).to eq("1")

      send_keys(:escape)
      expect(page).to have_no_css(".deck--presenting")
    end
  end

  describe "the pen" do
    it "paints a drag, holds the slide, and lets the stroke fade on its own" do
      visit plan_page_path(plan)
      start_show
      find(".deck-slide--current").click
      expect(current_slide).to eq("2")

      send_keys("d")
      expect(page).to have_css(".deck--inking .deck-ink-badge")

      watch_strokes
      drag_across(".deck-slide--current li")

      # The stroke is the point being made: the show holds, and the drag
      # paints instead of selecting.
      expect(strokes_drawn).to eq(1)
      expect(current_slide).to eq("2")
      expect(page.evaluate_script("document.getSelection().toString()")).to eq("")

      # Temporary by design — nothing to erase, nothing saved.
      expect(page).to have_no_css(".deck-ink__stroke", wait: 6)
    end

    it "still advances on a bare click, and leaves no dot behind" do
      visit plan_page_path(plan)
      start_show
      send_keys("d")
      expect(page).to have_css(".deck--inking")

      watch_strokes
      find(".deck-slide--current").click

      expect(current_slide).to eq("2")
      # A press that never travels is the presenter advancing the show, so
      # the pen must not even create a node — a one-frame dot under every
      # click reads as a rendering bug.
      expect(strokes_drawn).to eq(0)
      # The pen stays out across the slide change.
      expect(page).to have_css(".deck--inking .deck-ink-badge")
    end

    it "does not eat the next click when a stroke is cancelled mid-air" do
      visit plan_page_path(plan)
      start_show
      send_keys("d")
      expect(page).to have_css(".deck--inking")

      # The browser can take the pointer away mid-stroke (a touch becoming a
      # system gesture). No click follows a cancellation, so the pen must not
      # claim one — the next real click belongs to the show. Scripted because
      # a driver has no way to make the browser cancel a pointer.
      page.execute_script(<<~JS)
        const slide = document.querySelector(".deck-slide--current");
        const box = slide.getBoundingClientRect();
        const fire = (type, x, y) => slide.dispatchEvent(new PointerEvent(type, {
          pointerId: 7, isPrimary: true, button: 0, buttons: 1,
          bubbles: true, cancelable: true, clientX: x, clientY: y
        }));
        fire("pointerdown", box.left + 40, box.top + 40);
        for (let i = 1; i <= 20; i++) fire("pointermove", box.left + 40 + i * 8, box.top + 40);
        fire("pointercancel", box.left + 200, box.top + 40);
      JS

      # A cancelled stroke was never made.
      expect(page).to have_no_css(".deck-ink__stroke")

      find(".deck-slide--current").click
      expect(current_slide).to eq("2")
    end

    it "puts the pen away on Escape without ending the show" do
      visit plan_page_path(plan)
      start_show
      send_keys("d")
      expect(page).to have_css(".deck--inking")

      send_keys(:escape)
      expect(page).to have_no_css(".deck--inking")
      expect(page).to have_no_css(".deck-ink-badge")
      expect(page).to have_css(".deck--presenting")

      send_keys(:escape)
      expect(page).to have_no_css(".deck--presenting")
    end
  end

  describe "Mermaid diagrams on a slide" do
    it "keeps the expand control chip-sized instead of scaling it to the canvas" do
      visit plan_page_path(plan)
      2.times { find(".deck-toolbar__step--next").click }
      expect(page).to have_css(".deck-slide .mermaid-diagram__canvas > svg", wait: 15)

      sizes = page.evaluate_script(<<~JS)
        (() => {
          const diagram = document.querySelector(".deck-slide .mermaid-diagram");
          const icon = diagram.querySelector(".mermaid-diagram__expand svg");
          const box = el => Math.round(el.getBoundingClientRect().width);
          return { diagram: box(diagram.querySelector(".mermaid-diagram__canvas > svg")), icon: box(icon) };
        })()
      JS

      # The diagram still takes the stage; the chip's icon stays an icon.
      expect(sizes["diagram"]).to be > 200
      expect(sizes["icon"]).to be <= 24
    end

    # The deck sizes slide diagrams in cqi against the slide canvas. Those
    # rules address the SVG through the diagram's DOM, so a change to that
    # DOM can leave them matching nothing — silently, because a small
    # diagram still looks fine unsized.
    it "sizes a slide's diagram from the deck's rules, not the document's" do
      visit plan_page_path(plan)
      2.times { find(".deck-toolbar__step--next").click }
      expect(page).to have_css(".deck-slide .mermaid-diagram__canvas > svg", wait: 15)

      sizing = page.evaluate_script(<<~JS)
        (() => {
          const canvas = document.querySelector(".deck-slide .mermaid-diagram__canvas")
          const slide = canvas.closest(".deck-slide")
          const svg = canvas.querySelector("svg")
          const canvasStyle = getComputedStyle(canvas)
          const svgStyle = getComputedStyle(svg)
          return {
            stage: slide.classList.contains("deck-slide--stage"),
            bound: slide.classList.contains("deck-slide--stage")
              ? svgStyle.height
              : svgStyle.maxHeight,
            overflowX: canvasStyle.overflowX,
            paddingLeft: canvasStyle.paddingLeft,
            scrolling: canvas.closest(".mermaid-diagram").classList.contains("mermaid-diagram--scrolling"),
            fits: svg.getBoundingClientRect().height <= slide.getBoundingClientRect().height
          }
        })()
      JS

      # A cqi rule resolves to a pixel length; "none"/"auto" means the
      # selector missed and the slide is showing an unsized diagram.
      expect(sizing["bound"]).to match(/\d+(\.\d+)?px/)
      expect(sizing["fits"]).to be(true)

      # ...and none of the document's scroll-box treatment comes along: a
      # slide is a fixed frame, so the diagram is fitted to it rather than
      # pinned at its natural size behind a scrollbar.
      expect(sizing["overflowX"]).to eq("visible")
      expect(sizing["paddingLeft"]).to eq("0px")
      expect(sizing["scrolling"]).to be(false)
    end
  end

  describe "back-matter links" do
    it "scrolls to the attachments section without refetching the page" do
      plan.attachments.attach(
        io: StringIO.new("handout"), filename: "handout.txt", content_type: "text/plain"
      )

      visit plan_page_path(plan)
      expect(page).to have_css(".deck-slide", wait: 5)

      # Turbo counts a same-page fragment link as a full visit, so a bare
      # anchor here refetched and re-rendered the page — and the scroll it
      # then performed raced the deck's async rendering. Nothing may be
      # fetched, and the section must end up on screen.
      page.execute_script(<<~JS)
        window.__visited = false;
        document.addEventListener("turbo:visit", () => { window.__visited = true });
      JS

      find(".content-nav__footnote-link", text: "Attachments").click

      expect(page).to have_current_path(/#footnote-attachments\z/, url: true, wait: 5)
      expect(page.evaluate_script("window.__visited")).to be(false)

      # The jump is a smooth scroll, so poll rather than sample once.
      20.times { break if attachments_on_screen?; sleep 0.15 }
      expect(attachments_on_screen?).to be(true)
    end
  end
end
