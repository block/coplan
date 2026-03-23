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
