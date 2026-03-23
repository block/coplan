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

    it "renders the margin column" do
      visit plan_path(plan)
      expect(page).to have_css(".plan-layout__margin")
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

  describe "margin dots" do
    before { sign_in(author) }

    it "creates a dot for each anchored open thread" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Why not monolith?", user: reviewer)
      create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Consider MySQL", user: reviewer)

      visit plan_path(plan)
      expect(page).to have_css(".margin-dot--open", count: 2)
    end

    it "shows pending dots in amber and todo dots in blue" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Feedback", user: reviewer)
      todo_thread = create_anchored_thread(plan: plan, anchor_text: "PostgreSQL", body: "Consider MySQL", user: reviewer)
      todo_thread.accept!(author)

      visit plan_path(plan)
      expect(page).to have_css(".margin-dot--pending", count: 1)
      expect(page).to have_css(".margin-dot--todo", count: 1)
    end

    it "hides resolved dots by default" do
      thread = create_anchored_thread(plan: plan, anchor_text: "Redis", body: "Do we need caching?", user: reviewer)
      thread.resolve!(author)

      visit plan_path(plan)
      expect(page).not_to have_css(".margin-dot--resolved", visible: true)
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

    it "opens a popover when clicking a margin dot" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Why not monolith?", user: reviewer)
      visit plan_path(plan)

      find(".margin-dot--open").click

      expect(page).to have_css(".thread-popover", visible: true)
      expect(page).to have_content("Why not monolith?")
    end

    it "shows reply form for open threads" do
      create_anchored_thread(plan: plan, anchor_text: "microservices architecture", body: "Why not monolith?", user: reviewer)
      visit plan_path(plan)
      find("mark.anchor-highlight--open").click

      within(".thread-popover") do
        expect(page).to have_css("textarea[placeholder='Reply...']")
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
        expect(page).to have_button("Accept")
        expect(page).to have_button("Discard")
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
      expect(placeholder).to eq("Reply...")
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
      expect(placeholder).to eq("Reply...")
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
        textarea = find("textarea[placeholder='Reply...']")
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
        textarea = find("textarea[placeholder='Reply...']")
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
end
