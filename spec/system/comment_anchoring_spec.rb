require "rails_helper"

RSpec.describe "Comment anchoring", type: :system do
  let(:user) { create(:coplan_user, email: "testuser@example.com") }

  # Content with the word "Complete" appearing THREE times in different sections
  let(:plan_content) do
    <<~MARKDOWN
      # Complete Guide to Testing

      This document provides a Complete overview of our testing strategy.

      ## Goals

      We want to achieve Complete coverage of all critical paths.

      ## Timeline

      Q1 2026: Start implementation.
    MARKDOWN
  end

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Repeated Text Plan", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: plan_content, actor_type: "human", actor_id: user.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_content("Sign out")
  end

  def create_thread_on_occurrence(plan, occurrence_num, body: "A comment")
    thread = plan.comment_threads.create!(
      plan_version: plan.current_plan_version,
      created_by_user: user,
      anchor_text: "Complete",
      anchor_occurrence: occurrence_num
    )
    thread.comments.create!(author_type: "human", author_id: user.id, body_markdown: body)
    thread
  end

  def find_thread_element(thread)
    find("[data-thread-id='#{thread.id}']")
  end

  describe "rendering data attributes for occurrence index" do
    it "includes correct data-anchor-occurrence for the first occurrence" do
      thread = create_thread_on_occurrence(plan, 1, body: "First occurrence")

      visit plan_path(plan)
      expect(page).to have_content("First occurrence")

      el = find_thread_element(thread)
      expect(el["data-anchor-occurrence"]).to eq("0")
    end

    it "includes correct data-anchor-occurrence for the second occurrence" do
      thread = create_thread_on_occurrence(plan, 2, body: "Second occurrence")

      visit plan_path(plan)
      expect(page).to have_content("Second occurrence")

      el = find_thread_element(thread)
      expect(el["data-anchor-occurrence"]).to eq("1")
    end

    it "includes correct data-anchor-occurrence for the third occurrence" do
      thread = create_thread_on_occurrence(plan, 3, body: "Third occurrence")

      visit plan_path(plan)
      expect(page).to have_content("Third occurrence")

      el = find_thread_element(thread)
      expect(el["data-anchor-occurrence"]).to eq("2")
    end

    it "renders distinct occurrence indices for multiple threads on different occurrences" do
      t1 = create_thread_on_occurrence(plan, 1, body: "On first")
      t2 = create_thread_on_occurrence(plan, 3, body: "On third")

      visit plan_path(plan)

      el1 = find_thread_element(t1)
      el2 = find_thread_element(t2)

      expect(el1["data-anchor-occurrence"]).to eq("0")
      expect(el2["data-anchor-occurrence"]).to eq("2")
    end
  end

  # Helper: finds the closest block-level ancestor's text content for a mark element.
  # This is needed because surroundContents wraps text in <mark>, and the direct
  # parentElement might be another <mark> (for active highlights) rather than the <p>/<h1>.
  def ancestor_text_of(selector)
    page.evaluate_script(<<~JS)
      (() => {
        const mark = document.querySelector('#{selector}');
        if (!mark) return null;
        let el = mark;
        while (el.parentElement && !['P', 'H1', 'H2', 'H3', 'LI'].includes(el.parentElement.tagName)) {
          el = el.parentElement;
        }
        return (el.parentElement || el).textContent;
      })()
    JS
  end

  def all_ancestor_texts_of(selector)
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('#{selector}')).map(mark => {
        let el = mark;
        while (el.parentElement && !['P', 'H1', 'H2', 'H3', 'LI'].includes(el.parentElement.tagName)) {
          el = el.parentElement;
        }
        return (el.parentElement || el).textContent;
      })
    JS
  end

  describe "highlight positioning with repeated text" do
    it "highlights the correct occurrence in the rendered document" do
      # Anchor to the THIRD occurrence (in "Complete coverage")
      create_thread_on_occurrence(plan, 3, body: "Third one!")

      visit plan_path(plan)

      highlights = all("mark.anchor-highlight")
      expect(highlights.size).to eq(1)

      expect(ancestor_text_of("mark.anchor-highlight")).to include("Complete coverage")
    end

    it "highlights the first occurrence when occurrence index is 0" do
      create_thread_on_occurrence(plan, 1, body: "Heading comment")

      visit plan_path(plan)

      highlights = all("mark.anchor-highlight")
      expect(highlights.size).to eq(1)

      expect(ancestor_text_of("mark.anchor-highlight")).to include("Complete Guide")
    end

    it "creates separate highlights for threads on different occurrences" do
      create_thread_on_occurrence(plan, 1, body: "First")
      create_thread_on_occurrence(plan, 3, body: "Third")

      visit plan_path(plan)

      highlights = all("mark.anchor-highlight")
      expect(highlights.size).to eq(2)

      contexts = all_ancestor_texts_of("mark.anchor-highlight")
      expect(contexts.any? { |c| c.include?("Complete Guide") }).to be true
      expect(contexts.any? { |c| c.include?("Complete coverage") }).to be true
    end
  end

  describe "clicking anchor quote scrolls to correct occurrence" do
    it "scrolls to and highlights the correct occurrence" do
      thread = create_thread_on_occurrence(plan, 3, body: "Third one!")

      visit plan_path(plan)

      within(find_thread_element(thread)) do
        find(".comment-thread__anchor-quote").click
      end

      expect(page).to have_css("mark.anchor-highlight--active")
      expect(ancestor_text_of("mark.anchor-highlight--active")).to include("Complete coverage")
    end
  end

  describe "resolved comment anchoring" do
    it "preserves correct anchor position after resolve and page reload" do
      thread = create_thread_on_occurrence(plan, 1, body: "Heading comment")

      visit plan_path(plan)

      # Resolve the thread
      within(find_thread_element(thread)) do
        click_link "Resolve"
      end

      # Reload the page
      visit plan_path(plan)

      # Switch to the Resolved tab
      click_button "Resolved"

      # The thread should still have the correct occurrence index
      el = find_thread_element(thread)
      expect(el["data-anchor-occurrence"]).to eq("0")

      # Click the anchor quote — it should highlight the correct occurrence
      within(el) do
        find(".comment-thread__anchor-quote").click
      end

      expect(page).to have_css("mark.anchor-highlight--active")
      expect(ancestor_text_of("mark.anchor-highlight--active")).to include("Complete Guide")
    end
  end

  describe "creating a comment via the form" do
    it "creates a thread with correct anchor position" do
      visit plan_path(plan)
      expect(page).to have_content("Complete Guide to Testing")

      # Simulate what the JS text-selection flow does: fill hidden fields and submit.
      # Without anchor_occurrence, resolve_anchor_position defaults to the first match.
      page.execute_script <<~JS
        const form = document.getElementById('new-comment-form');
        form.style.display = 'block';
        form.querySelector('[name="comment_thread[anchor_text]"]').value = 'Complete';
        form.querySelector('[name="comment_thread[anchor_context]"]').value = '';
      JS

      within("#new-comment-form") do
        fill_in "comment_thread[body_markdown]", with: "This word appears multiple times!"
        click_button "Comment"
      end

      # Wait for the form to process
      expect(page).not_to have_css("#new-comment-form", visible: true)

      # Verify the thread was created with anchor positions resolved to the first occurrence
      thread = plan.comment_threads.reload.last
      expect(thread).to be_present
      expect(thread.anchor_text).to eq("Complete")
      expect(thread.anchor_start).to eq(plan_content.index("Complete"))
      expect(thread.anchor_occurrence_index).to eq(0)
    end
  end
end
