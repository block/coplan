require "rails_helper"

RSpec.describe "Collapsible document outline", type: :system do
  let(:author) { create(:coplan_user, email: "outline-author@example.com") }
  let(:plan) { create(:plan, :published, title: "Long review", created_by_user: author) }

  def long_content
    areas = %w[Scope Context Architecture Correctness Availability Dependencies Security Observability Operations Findings]
    sections = areas.each_with_index.map do |area, index|
      number = index + 1
      subsections = (1..3).map do |sub|
        paragraphs = (1..3).map { |paragraph| "Notes for #{number}.#{sub}, paragraph #{paragraph}. " + "Supporting detail for this part of the review. " * 6 }
        "### #{number}.#{sub} #{area} detail #{sub}\n\n#{paragraphs.join("\n\n")}"
      end
      "## #{number}. #{area}\n\nOverview of #{area.downcase}.\n\n#{subsections.join("\n\n")}"
    end
    "# Long review\n\nIntroduction.\n\n#{sections.join("\n\n")}\n"
  end

  def replace_content(content)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  def chevron(text)
    find(".content-nav__disclosure[aria-label='#{text} sub-sections']")
  end

  def expect_expanded(text, expanded)
    expect(page).to have_css(".content-nav__disclosure[aria-label='#{text} sub-sections'][aria-expanded='#{expanded}']")
  end

  def expect_entry_visible(text, visible)
    if visible
      expect(page).to have_css(".content-nav__link-text", exact_text: text, visible: true)
    else
      expect(page).to have_no_css(".content-nav__link-text", exact_text: text, visible: true)
    end
  end

  def heading_id(text)
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(".content-nav__item"))
        .find(item => item.querySelector(":scope > .content-nav__row .content-nav__link-text").textContent === #{text.to_json})
        .dataset.headingId
    JS
  end

  def scroll_to_heading(text)
    page.execute_script(<<~JS)
      Array.from(document.querySelectorAll("#plan-content-body h2, #plan-content-body h3"))
        .find(heading => heading.textContent.trim() === #{text.to_json})
        .scrollIntoView({ block: "start" })
    JS
  end

  before { sign_in(author) }

  context "with a long outline" do
    before { replace_content(long_content) }

    it "starts with every section folded except the one being read" do
      visit plan_page_path(plan)

      expect(page).to have_css(".content-nav__disclosure", count: 10)
      expect(page).to have_css(".content-nav__disclosure[aria-expanded='false']", count: 10)
      # The title holds the whole outline, so it never folds.
      expect(page).to have_no_css(".content-nav__disclosure[aria-label='Long review sub-sections']")
      expect_entry_visible("4. Correctness", true)
      expect_entry_visible("4.1 Correctness detail 1", false)
      expect(page).to have_css(".content-nav__tree-controls", visible: true)
    end

    it "toggles a section from its chevron or arrow keys while the label navigates" do
      visit plan_page_path(plan)

      chevron("2. Context").click
      expect_expanded("2. Context", true)
      expect_entry_visible("2.1 Context detail 1", true)
      expect(page.evaluate_script("window.location.hash")).to eq("")
      expect(page.evaluate_script("window.scrollY")).to eq(0)

      chevron("2. Context").click
      expect_expanded("2. Context", false)
      expect_entry_visible("2.1 Context detail 1", false)

      find(".content-nav__link-text", exact_text: "5. Availability").click
      expect(page).to have_current_path(/##{heading_id("5. Availability")}\z/, url: true)
      Selenium::WebDriver::Wait.new(timeout: 5).until do
        page.evaluate_script("document.getElementById(#{heading_id("5. Availability").to_json}).getBoundingClientRect().top").between?(0, 150)
      end
      expect_expanded("5. Availability", false)

      find(".content-nav__link", text: "5. Availability").send_keys(:arrow_right)
      expect_expanded("5. Availability", true)
      expect_entry_visible("5.2 Availability detail 2", true)
      find(".content-nav__link", text: "5. Availability").send_keys(:arrow_left)
      expect_expanded("5. Availability", false)
    end

    it "unfolds the section containing the heading scrolled into view and leaves others alone" do
      visit plan_page_path(plan)
      chevron("2. Context").click
      expect_expanded("2. Context", true)

      scroll_to_heading("6.2 Dependencies detail 2")

      expect_expanded("6. Dependencies", true)
      expect(page).to have_css(".content-nav__link--active", text: "6.2 Dependencies detail 2")
      expect_expanded("2. Context", true)
      expect_expanded("8. Observability", false)

      scroll_to_heading("9.1 Operations detail 1")
      expect_expanded("9. Operations", true)
      expect_expanded("6. Dependencies", true)
    end

    it "unfolds the target of a section link" do
      visit plan_page_path(plan)
      section_id = heading_id("7. Security")
      subsection_id = heading_id("8.2 Observability detail 2")

      visit root_path
      visit "#{plan_page_path(plan)}##{section_id}"
      expect_expanded("7. Security", true)
      expect_entry_visible("7.1 Security detail 1", true)
      expect_expanded("3. Architecture", false)

      visit root_path
      visit "#{plan_page_path(plan)}##{subsection_id}"
      expect_expanded("8. Observability", true)
      expect_entry_visible("8.2 Observability detail 2", true)
      expect_expanded("3. Architecture", false)
    end

    it "expands and collapses every section" do
      visit plan_page_path(plan)

      find("button[aria-label='Expand all sections']").click
      expect(page).to have_css(".content-nav__disclosure[aria-expanded='true']", count: 10)
      expect_entry_visible("10.3 Findings detail 3", true)

      find("button[aria-label='Collapse all sections']").click
      expect(page).to have_css(".content-nav__disclosure[aria-expanded='false']", count: 10)
      expect_entry_visible("1.1 Scope detail 1", false)
    end

    it "remembers the reader's toggles across reloads and Turbo navigation, ignoring stale keys" do
      visit plan_page_path(plan)
      chevron("3. Architecture").click
      expect_expanded("3. Architecture", true)
      page.execute_script(<<~JS)
        const key = Object.keys(sessionStorage).find(key => key.startsWith("coplan:outline-expanded:"))
        sessionStorage.setItem(key, JSON.stringify({ ...JSON.parse(sessionStorage.getItem(key)), "no-such-heading": true }))
      JS

      page.refresh
      expect_expanded("3. Architecture", true)
      expect_entry_visible("3.1 Architecture detail 1", true)
      expect_expanded("4. Correctness", false)

      visit root_path
      page.go_back
      expect_expanded("3. Architecture", true)
      expect_expanded("4. Correctness", false)
    end

    it "keeps toggles when a live update rebuilds the outline" do
      visit plan_page_path(plan)
      chevron("3. Architecture").click
      expect_expanded("3. Architecture", true)

      replace_content(long_content.sub("## 10. Findings", "## 10. Findings and actions"))
      expect(page).to have_css(".content-nav__link-text", exact_text: "10. Findings and actions", wait: 10)
      expect_expanded("3. Architecture", true)
      expect_expanded("4. Correctness", false)
    end

    it "totals open discussions from folded sub-sections on the parent" do
      reviewer = create(:coplan_user)
      [ "Notes for 4.1, paragraph 2", "Notes for 4.2, paragraph 1" ].each do |anchor|
        thread = plan.comment_threads.create!(plan_version: plan.current_plan_version, anchor_text: anchor,
          anchor_occurrence: 1, created_by_user: reviewer, status: "open")
        thread.comments.create!(author_type: "human", author_id: reviewer.id, body_markdown: "Question about #{anchor}")
      end
      visit plan_page_path(plan)

      parent = find(".content-nav__row", text: "4. Correctness")
      expect(parent).to have_css(".content-nav__badge", exact_text: "2")

      chevron("4. Correctness").click
      expect(parent).to have_no_css(".content-nav__badge")
      expect(find(".content-nav__row", text: "4.1 Correctness detail 1")).to have_css(".content-nav__badge", exact_text: "1")
      expect(find(".content-nav__row", text: "4.2 Correctness detail 2")).to have_css(".content-nav__badge", exact_text: "1")
    end

    it "folds the editor outline and keeps its state as headings change" do
      visit plan_page_path(plan)
      within("#plan-toolbar") { click_link "Edit" }
      expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)

      expect(page).to have_css(".content-nav__disclosure", count: 10)
      chevron("4. Correctness").click
      expect_expanded("4. Correctness", true)
      expect_entry_visible("4.1 Correctness detail 1", true)

      find(".inline-editor .ProseMirror h2", text: "9. Operations").click
      page.driver.browser.action.send_keys(:end, " revised").perform
      expect(page).to have_css(".content-nav__link-text", exact_text: "9. Operations revised", wait: 10)
      expect_expanded("4. Correctness", true)

      find(".inline-editor .ProseMirror h2", text: "4. Correctness").click
      page.driver.browser.action.send_keys(:end, " notes").perform
      expect(page).to have_css(".content-nav__link-text", exact_text: "4. Correctness notes", wait: 10)
      expect_expanded("4. Correctness notes", true)
      expect_entry_visible("4.1 Correctness detail 1", true)

      find(".content-nav__link-text", exact_text: "10. Findings").click
      Selenium::WebDriver::Wait.new(timeout: 5).until do
        top = page.evaluate_script("Array.from(document.querySelectorAll('.inline-editor .ProseMirror h2')).find(h => h.textContent.includes('10. Findings')).getBoundingClientRect().top")
        top.between?(0, page.evaluate_script("window.innerHeight"))
      end
    end
  end

  it "leaves a short outline flat and fully expanded" do
    replace_content("# Short plan\n\n## Background\n\nText.\n\n### History\n\nText.\n\n## Proposal\n\nText.\n")
    visit plan_page_path(plan)

    expect_entry_visible("History", true)
    expect_entry_visible("Proposal", true)
    expect(page).to have_no_css(".content-nav__disclosure")
    expect(page).to have_no_css(".content-nav__disclosure-spacer")
    expect(page).to have_no_css(".content-nav__tree-controls", visible: true)
  end

  it "leaves a long outline with nothing to fold unchanged" do
    replace_content("# Flat plan\n\n" + (1..15).map { |n| "## Topic #{n}\n\nText #{n}." }.join("\n\n"))
    visit plan_page_path(plan)

    expect_entry_visible("Topic 15", true)
    expect(page).to have_no_css(".content-nav__disclosure")
    expect(page).to have_no_css(".content-nav__disclosure-spacer")
    expect(page).to have_no_css(".content-nav__tree-controls", visible: true)
  end
end
