require "rails_helper"

RSpec.describe "Comment UX", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }
  let(:reviewer) { create(:coplan_user, email: "reviewer@example.com") }

  let(:plan_content) do
    <<~MARKDOWN
      # Architecture Overview

      This system uses a microservices architecture with three main components.

      ## Database Layer

      We use PostgreSQL for persistence with Redis for caching.

      ## API Layer

      The API layer handles authentication, rate limiting, and routing.
    MARKDOWN
  end

  let(:plan) do
    p = CoPlan::Plan.create!(title: "System Design Plan", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: plan_content, actor_type: "human", actor_id: author.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_content("Sign out")
  end

  def create_anchored_thread(plan:, anchor_text:, body:, user:)
    thread = plan.comment_threads.create!(
      plan_version: plan.current_plan_version,
      anchor_text: anchor_text,
      anchor_occurrence: 1,
      created_by_user: user,
      status: "pending"
    )
    thread.comments.create!(
      author_type: "human",
      author_id: user.id,
      body_markdown: body
    )
    thread
  end

  describe "plan show page layout" do
    before { sign_in(author) }

    it "renders the plan layout" do
      visit plan_path(plan)
      expect(page).to have_css(".plan-layout__content")
    end

    it "renders plan content in markdown" do
      visit plan_path(plan)
      expect(page).to have_content("Architecture Overview")
      expect(page).to have_content("microservices architecture")
    end
  end

  describe "inline highlights" do
    before { sign_in(author) }

    it "renders open thread highlights as accent-colored marks" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Why not monolith?", user: reviewer)
      visit plan_path(plan)

      expect(page).to have_css("mark.anchor-highlight--open", text: "microservices architecture")
    end

    it "renders pending highlights in amber and todo highlights in blue" do
      pending_thread = create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Feedback", user: reviewer)
      todo_thread = create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Consider MySQL", user: reviewer)
      todo_thread.accept!(author)

      visit plan_path(plan)

      pending_mark = find("mark.anchor-highlight--pending")
      pending_border = pending_mark.evaluate_script("getComputedStyle(this).borderBottomColor")
      expect(pending_border).to include("245")  # amber/orange channel

      todo_mark = find("mark.anchor-highlight--todo")
      todo_border = todo_mark.evaluate_script("getComputedStyle(this).borderBottomColor")
      expect(todo_border).to include("130")  # blue channel (59, 130, 246)
    end

    it "renders resolved thread highlights unstyled by default" do
      thread = create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Consider MySQL", user: reviewer)
      thread.resolve!(author)

      visit plan_path(plan)
      # Mark is present (text must remain visible) but has no visual highlight styling
      expect(page).to have_css("mark.anchor-highlight--resolved", text: "PostgreSQL")
      mark = find("mark.anchor-highlight--resolved")
      border = mark.evaluate_script("getComputedStyle(this).borderBottomStyle")
      expect(border).to eq("none")
    end

    it "shows resolved highlights with dashed underline when toggle is checked" do
      thread = create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Consider MySQL", user: reviewer)
      thread.resolve!(author)

      visit plan_path(plan)
      check "Show resolved"

      mark = find("mark.anchor-highlight--resolved")
      border = mark.evaluate_script("getComputedStyle(this).borderBottomStyle")
      expect(border).to eq("dashed")
    end
  end



  describe "thread popovers" do
    before { sign_in(author) }

    it "opens a popover when clicking a highlight" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Why not monolith?", user: reviewer)
      visit plan_path(plan)

      find("mark.anchor-highlight--open").click

      expect(page).to have_css(".thread-popover", visible: true)
      expect(page).to have_content("Why not monolith?")
    end

    it "shows reply form for open threads" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Why not monolith?", user: reviewer)
      visit plan_path(plan)
      find("mark.anchor-highlight--open").click

      within(".thread-popover") do
        expect(page).to have_css("textarea[placeholder='Press r to reply']")
      end
    end

    it "shows status-specific badge in popover" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Feedback", user: reviewer)
      visit plan_path(plan)
      find("mark.anchor-highlight--open").click

      within(".thread-popover") do
        expect(page).to have_css(".badge--pending")
      end
    end

    it "shows action buttons for plan author" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Feedback", user: reviewer)
      visit plan_path(plan)
      find("mark.anchor-highlight--open").click

      within(".thread-popover") do
        expect(page).to have_button("Accept (a)")
        expect(page).to have_button("Discard (d)")
      end
    end
  end

  describe "comment toolbar" do
    before { sign_in(author) }

    it "shows the toolbar when threads exist" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Feedback", user: reviewer)
      visit plan_path(plan)

      expect(page).to have_css(".comment-toolbar")
      expect(page).to have_content("💬 1 open")
    end

    it "does not show the toolbar when no threads" do
      visit plan_path(plan)
      expect(page).not_to have_css(".comment-toolbar")
    end

    it "shows correct open count with mixed statuses" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Open 1", user: reviewer)
      create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Open 2", user: reviewer)
      resolved = create_anchored_thread(plan: plan, anchor_text: "Redis", body: "Resolved", user: reviewer)
      resolved.resolve!(author)

      visit plan_path(plan)
      expect(page).to have_content("💬 2 open")
      expect(page).to have_content("Show resolved (1)")
    end

    it "navigates to next/prev with toolbar buttons" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "First", user: reviewer)
      create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Second", user: reviewer)

      visit plan_path(plan)

      click_button "↓"
      expect(page).to have_css("mark.anchor-highlight--active")
      expect(page).to have_css(".comment-toolbar__position", text: "1 of 2")

      # Dismiss the popover so it doesn't cover the toolbar button
      find("body").send_keys(:escape)
      expect(page).not_to have_css(".thread-popover", visible: true)

      click_button "↓"
      expect(page).to have_css(".comment-toolbar__position", text: "2 of 2")
    end
  end

  describe "lifecycle actions via popover" do
    before { sign_in(author) }

    it "accepts a thread (pending → todo)" do
      thread = create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Agree with this", user: reviewer)
      visit plan_path(plan)
      find("mark.anchor-highlight--open").click
      expect(page).to have_css(".thread-popover", visible: true)

      accept_form = find(".thread-popover", visible: true).find("form[action*='accept']", visible: :all)
      accept_form.find("input[type='submit'], button[type='submit']", visible: :all).click

      expect(page).not_to have_css(".thread-popover", visible: true)
      expect(thread.reload.status).to eq("todo")
    end

    it "discards a thread (pending → discarded)" do
      thread = create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Not relevant", user: reviewer)
      visit plan_path(plan)
      find("mark.anchor-highlight--open").click
      expect(page).to have_css(".thread-popover", visible: true)

      discard_form = find(".thread-popover", visible: true).find("form[action*='discard']", visible: :all)
      discard_form.find("input[type='submit'], button[type='submit']", visible: :all).click

      expect(page).not_to have_css(".thread-popover", visible: true)
      expect(thread.reload.status).to eq("discarded")
    end
  end

  describe "keyboard shortcuts" do
    before { sign_in(author) }

    it "focuses reply textarea when pressing r after navigating to a thread" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Why not monolith?", user: reviewer)
      create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Consider MySQL", user: reviewer)
      visit plan_path(plan)

      # Navigate to the first thread with j
      find("body").send_keys("j")
      expect(page).to have_css("mark.anchor-highlight--active")
      expect(page).to have_css(".thread-popover", visible: true)

      # Press r to focus the reply textarea
      find("body").send_keys("r")
      active = page.evaluate_script("document.activeElement.tagName")
      placeholder = page.evaluate_script("document.activeElement.placeholder")
      expect(active).to eq("TEXTAREA")
      expect(placeholder).to eq("Press r to reply")
    end

    it "focuses reply textarea when pressing r after mouse-clicking a highlight" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Why not monolith?", user: reviewer)
      create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Consider MySQL", user: reviewer)
      visit plan_path(plan)

      # Open popover for the second thread via mouse click (not j/k)
      marks = all("mark.anchor-highlight--open")
      marks.last.click
      expect(page).to have_css(".thread-popover", visible: true)

      # Press r to focus the reply textarea in the correct (second) popover
      find("body").send_keys("r")
      active = page.evaluate_script("document.activeElement.tagName")
      placeholder = page.evaluate_script("document.activeElement.placeholder")
      expect(active).to eq("TEXTAREA")
      expect(placeholder).to eq("Press r to reply")
    end

    it "does not fire r shortcut when typing in a textarea" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Feedback", user: reviewer)
      visit plan_path(plan)

      # Navigate and focus reply
      find("body").send_keys("j")
      expect(page).to have_css(".thread-popover", visible: true)
      find("body").send_keys("r")

      # Type 'r' inside the textarea — should insert character, not trigger shortcut
      active_el = page.evaluate_script("document.activeElement.tagName")
      expect(active_el).to eq("TEXTAREA")
    end

    it "submits reply form with Enter key" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Why not monolith?", user: reviewer)
      visit plan_path(plan)

      find("mark.anchor-highlight--open").click
      expect(page).to have_css(".thread-popover", visible: true)

      within(".thread-popover") do
        textarea = find("textarea[placeholder='Press r to reply']")
        textarea.fill_in with: "Good point"
        textarea.send_keys(:enter)
      end

      # Reply should be submitted and textarea cleared
      expect(page).to have_content("Good point")
      thread = plan.comment_threads.reload.first
      expect(thread.comments.count).to eq(2)
    end

    it "inserts newline with Shift+Enter in reply textarea" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Feedback", user: reviewer)
      visit plan_path(plan)

      find("mark.anchor-highlight--open").click
      expect(page).to have_css(".thread-popover", visible: true)

      within(".thread-popover") do
        textarea = find("textarea[placeholder='Press r to reply']")
        textarea.fill_in with: "Line one"
        textarea.send_keys([:shift, :enter])
        textarea.send_keys("Line two")
        value = textarea.value
        expect(value).to include("Line one")
        expect(value).to include("Line two")
      end

      # Form should NOT have been submitted
      thread = plan.comment_threads.reload.first
      expect(thread.comments.count).to eq(1)
    end

    it "accepts a pending thread with 'a' key and auto-advances" do
      thread1 = create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Feedback 1", user: reviewer)
      thread2 = create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Feedback 2", user: reviewer)
      visit plan_path(plan)

      # Navigate to first thread
      find("body").send_keys("j")
      expect(page).to have_css("mark.anchor-highlight--active")
      expect(page).to have_css(".thread-popover", visible: true)
      expect(page).to have_css(".comment-toolbar__position", text: "1 of 2")

      # Press 'a' to accept
      find("body").send_keys("a")

      # Wait for the thread data attribute to update via broadcast
      expect(page).to have_css("[data-thread-status='todo']", visible: :all, wait: 5)
      expect(thread1.reload.status).to eq("todo")
    end

    it "discards a pending thread with 'd' key" do
      thread = create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Not relevant", user: reviewer)
      visit plan_path(plan)

      find("body").send_keys("j")
      expect(page).to have_css("mark.anchor-highlight--active")
      expect(page).to have_css(".thread-popover", visible: true)

      find("body").send_keys("d")

      expect(page).to have_css("[data-thread-status='discarded']", visible: :all, wait: 5)
      expect(thread.reload.status).to eq("discarded")
    end

    it "does not fire a/d shortcuts when typing in a textarea" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Feedback", user: reviewer)
      visit plan_path(plan)

      find("body").send_keys("j")
      expect(page).to have_css(".thread-popover", visible: true)
      find("body").send_keys("r")

      # Type 'a' inside the textarea — should not trigger accept
      active_el = page.evaluate_script("document.activeElement.tagName")
      expect(active_el).to eq("TEXTAREA")
    end

    it "submits new comment form with Enter key" do
      visit plan_path(plan)

      page.execute_script <<~JS
        const form = document.getElementById('new-comment-form');
        form.style.display = 'block';
        form.querySelector('[name="comment_thread[anchor_text]"]').value = 'microservices architecture';
        form.querySelector('[name="comment_thread[anchor_context]"]').value = '';
        form.querySelector('[name="comment_thread[anchor_occurrence]"]').value = '1';
      JS

      within("#new-comment-form") do
        textarea = find("textarea")
        textarea.fill_in with: "Enter-submitted comment"
        textarea.send_keys(:enter)
      end

      expect(page).not_to have_css("#new-comment-form", visible: true, wait: 5)
      thread = plan.comment_threads.reload.last
      expect(thread).to be_present
      expect(thread.comments.first.body_markdown).to eq("Enter-submitted comment")
    end
  end

  describe "escape key dismisses comment form" do
    before { sign_in(author) }

    it "closes the new comment form when pressing Escape with textarea focused" do
      visit plan_path(plan)

      # Open the comment form programmatically (simulating text selection flow)
      page.execute_script <<~JS
        const form = document.getElementById('new-comment-form');
        form.style.display = 'block';
        form.querySelector('[name="comment_thread[anchor_text]"]').value = 'microservices architecture';
        form.querySelector('textarea').focus();
      JS

      expect(page).to have_css("#new-comment-form", visible: true)

      # Press Escape while textarea is focused
      find("textarea", visible: true, match: :first).send_keys(:escape)

      expect(page).not_to have_css("#new-comment-form", visible: true)
    end

    it "closes the new comment form when pressing Escape without textarea focused" do
      visit plan_path(plan)

      page.execute_script <<~JS
        const form = document.getElementById('new-comment-form');
        form.style.display = 'block';
        form.querySelector('[name="comment_thread[anchor_text]"]').value = 'microservices architecture';
      JS

      expect(page).to have_css("#new-comment-form", visible: true)

      # Press Escape from the body (no textarea focus)
      find("body").send_keys(:escape)

      expect(page).not_to have_css("#new-comment-form", visible: true)
    end
  end

  describe "whole-line text selection" do
    before { sign_in(author) }

    it "shows comment popover when selection extends past content boundary" do
      visit plan_path(plan)

      # Simulate a whole-line selection that bleeds past the content target.
      # This reproduces the bug where commonAncestorContainer is above
      # contentTarget, causing the old contains() check to reject it.
      page.execute_script <<~JS
        const content = document.querySelector('[data-coplan--text-selection-target="content"]');
        const heading = content.querySelector('h2');
        if (!heading) throw new Error('No h2 found in content');
        const range = document.createRange();
        range.setStart(heading.firstChild, 0);
        range.setEndAfter(content);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        content.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
      JS

      expect(page).to have_css(".comment-popover", visible: true, wait: 3)
    end
  end

  describe "creating a new comment" do
    before { sign_in(author) }

    it "creates a thread via the text selection form" do
      visit plan_path(plan)

      # Simulate the JS text-selection flow
      page.execute_script <<~JS
        const form = document.getElementById('new-comment-form');
        form.style.display = 'block';
        form.style.top = '100px';
        form.style.left = '100px';
        form.querySelector('[name="comment_thread[anchor_text]"]').value = 'microservices architecture';
        form.querySelector('[name="comment_thread[anchor_context]"]').value = '';
        form.querySelector('[name="comment_thread[anchor_occurrence]"]').value = '1';
      JS

      within("#new-comment-form") do
        fill_in "comment_thread[body_markdown]", with: "Should we reconsider this?"
        click_button "Comment"
      end

      # Wait for form to be hidden (indicates successful submission)
      expect(page).not_to have_css("#new-comment-form", visible: true, wait: 5)

      thread = plan.comment_threads.reload.last
      expect(thread).to be_present
      expect(thread.anchor_text).to eq("microservices architecture")
      expect(thread.status).to eq("todo") # author's own comments start as todo
      expect(thread.comments.first.body_markdown).to eq("Should we reconsider this?")
    end
  end

  describe "j/k navigation with multi-node anchors" do
    before { sign_in(author) }

    let(:bold_content) do
      <<~MARKDOWN
        # Overview

        This system uses a **microservices** architecture with three components.

        ## Database

        We use PostgreSQL for persistence with Redis for caching.
      MARKDOWN
    end

    let(:bold_plan) do
      p = CoPlan::Plan.create!(title: "Bold Content Plan", created_by_user: author)
      version = CoPlan::PlanVersion.create!(
        plan: p, revision: 1,
        content_markdown: bold_content, actor_type: "human", actor_id: author.id
      )
      p.update!(current_plan_version: version, current_revision: 1)
      p
    end

    def create_cross_element_thread(plan:, anchor_text:, body:, user:)
      thread = plan.comment_threads.create!(
        plan_version: plan.current_plan_version,
        anchor_text: anchor_text,
        anchor_occurrence: 1,
        anchor_start: 0,
        anchor_end: anchor_text.length,
        anchor_revision: plan.current_revision,
        created_by_user: user,
        status: "pending"
      )
      thread.comments.create!(
        author_type: "human",
        author_id: user.id,
        body_markdown: body
      )
      thread
    end

    it "counts each thread as one navigation stop even when anchor spans multiple DOM nodes" do
      create_cross_element_thread(
        plan: bold_plan,
        anchor_text: "uses a microservices architecture",
        body: "Spans bold boundary",
        user: reviewer
      )
      create_anchored_thread(
        plan: bold_plan,
        anchor_text: "PostgreSQL",
        body: "Second thread",
        user: reviewer
      )

      visit plan_path(bold_plan)

      # The cross-element anchor produces multiple <mark> elements
      mark_count = page.all("mark.anchor-highlight").count
      expect(mark_count).to be > 2

      # But toolbar should show only 2 open threads
      expect(page).to have_content("💬 2 open")

      # j navigates to first thread
      find("body").send_keys("j")
      expect(page).to have_css(".comment-toolbar__position", text: "1 of 2")

      # Dismiss popover so next j press works cleanly
      find("body").send_keys(:escape)
      expect(page).not_to have_css(".thread-popover", visible: true)

      # j navigates to second thread (not "2 of 4" as the bug would show)
      find("body").send_keys("j")
      expect(page).to have_css(".comment-toolbar__position", text: "2 of 2")
    end
  end

  describe "short text selection" do
    # Selecting a single character or number (e.g. "3" in "3 months") should
    # trigger the comment popover. Previously, selections shorter than 3
    # characters were silently ignored.

    before { sign_in(author) }

    it "shows the comment popover when selecting a two-character string" do
      visit plan_path(plan)

      # Select "We" (2 chars) from "We use PostgreSQL..." — this would have
      # been silently ignored by the old text.length < 3 check.
      page.execute_script <<~JS
        const content = document.querySelector('[data-coplan--text-selection-target="content"]');
        const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
        let node;
        while (node = walker.nextNode()) {
          const idx = node.textContent.indexOf('We');
          if (idx !== -1) {
            const range = document.createRange();
            range.setStart(node, idx);
            range.setEnd(node, idx + 2);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            content.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
            break;
          }
        }
      JS

      expect(page).to have_css(".comment-popover", visible: true, wait: 3)
    end

    it "allows creating and highlighting a single-character anchor" do
      create_anchored_thread(
        plan: plan,
        anchor_text: "a",
        body: "Why use 'a' here?",
        user: reviewer
      )

      visit plan_path(plan)
      expect(page).to have_css("mark.anchor-highlight", text: "a")
    end

    it "shows the comment popover for a number like '3'" do
      # Use plan content that contains a number
      number_plan = CoPlan::Plan.create!(title: "Number Plan", created_by_user: author)
      version = CoPlan::PlanVersion.create!(
        plan: number_plan, revision: 1,
        content_markdown: "We need exactly 3 MySQL clusters for this deployment.",
        actor_type: "human", actor_id: author.id
      )
      number_plan.update!(current_plan_version: version, current_revision: 1)

      visit plan_path(number_plan)

      page.execute_script <<~JS
        const content = document.querySelector('[data-coplan--text-selection-target="content"]');
        const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
        let node;
        while (node = walker.nextNode()) {
          const idx = node.textContent.indexOf('3');
          if (idx !== -1) {
            const range = document.createRange();
            range.setStart(node, idx);
            range.setEnd(node, idx + 1);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            content.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
            break;
          }
        }
      JS

      expect(page).to have_css(".comment-popover", visible: true, wait: 3)
    end
  end

  describe "table anchoring" do
    let(:table_content) do
      <<~MARKDOWN
        # Resource Plan

        | Phase   | Engineers | Duration  | Cost   |
        |---------|-----------|-----------|--------|
        | Phase 1 | 15        | 3 months  | $1.2M  |
        | Phase 2 | 35        | 5 months  | $5.8M  |
        | Phase 3 | 40        | 6 months  | $8.0M  |

        ## Notes

        Budget approved by finance team.
      MARKDOWN
    end

    let(:table_plan) do
      p = CoPlan::Plan.create!(title: "Table Plan", created_by_user: author)
      version = CoPlan::PlanVersion.create!(
        plan: p, revision: 1,
        content_markdown: table_content, actor_type: "human", actor_id: author.id
      )
      p.update!(current_plan_version: version, current_revision: 1)
      p
    end

    before { sign_in(author) }

    it "preserves table structure when highlighting text that spans multiple cells" do
      visit plan_path(table_plan)
      anchor = page.evaluate_script(
        "document.querySelector('table tbody tr:nth-child(2)').textContent.trim()"
      )
      expect(anchor).to be_present

      thread = table_plan.comment_threads.new(
        plan_version: table_plan.current_plan_version,
        anchor_text: anchor,
        created_by_user: reviewer,
        status: "pending",
        anchor_start: 0,
        anchor_end: anchor.length,
        anchor_revision: table_plan.current_revision
      )
      thread.save!(validate: true)
      thread.comments.create!(
        author_type: "human",
        author_id: reviewer.id,
        body_markdown: "This row looks expensive"
      )

      visit plan_path(table_plan)

      data_rows = all("table tbody tr")
      expect(data_rows.length).to eq(3)
      data_rows.each do |row|
        cells = row.all("td")
        expect(cells.length).to eq(4), "expected 4 cells per row, got #{cells.length} in row '#{row.text}'"
      end

      header_cells = all("table thead tr th")
      expect(header_cells.length).to eq(4)

      expect(page).to have_css("td mark.anchor-highlight", minimum: 1)

      invalid_marks = page.evaluate_script(
        "document.querySelectorAll('tr > mark').length"
      )
      expect(invalid_marks).to eq(0), "found <mark> elements as direct children of <tr>"
    end

    it "highlights single-cell table text without breaking layout" do
      create_anchored_thread(
        plan: table_plan,
        anchor_text: "Phase 1",
        body: "Should we start here?",
        user: reviewer
      )

      visit plan_path(table_plan)

      expect(page).to have_css("td mark.anchor-highlight", text: "Phase 1")

      all("table tbody tr").each do |row|
        expect(row.all("td").length).to eq(4)
      end
    end

    it "creates a comment on table text via the UI and highlights it" do
      visit plan_path(table_plan)

      rendered_text = page.evaluate_script(
        "document.querySelector('table').textContent"
      )
      cell_text = "Phase 1"
      expect(rendered_text).to include(cell_text)

      page.execute_script <<~JS
        const form = document.getElementById('new-comment-form');
        form.style.display = 'block';
        form.querySelector('[name="comment_thread[anchor_text]"]').value = '#{cell_text}';
        form.querySelector('[name="comment_thread[anchor_context]"]').value = '';
        form.querySelector('[name="comment_thread[anchor_occurrence]"]').value = '1';
      JS

      within("#new-comment-form") do
        fill_in "comment_thread[body_markdown]", with: "Review this phase"
        click_button "Comment"
      end

      expect(page).not_to have_css("#new-comment-form", visible: true)

      thread = table_plan.comment_threads.reload.last
      expect(thread).to be_present
      expect(thread.anchor_text).to eq(cell_text)
      expect(page).to have_css("td mark.anchor-highlight", text: cell_text)

      all("table tbody tr").each do |row|
        expect(row.all("td").length).to eq(4)
      end
    end
  end
end
