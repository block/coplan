require "rails_helper"

RSpec.describe "Comment anchoring", type: :system do
  let(:user) { create(:coplan_user, email: "testuser@example.com") }

  # Content with the word "Complete" appearing THREE times in different sections
  let(:plan_content) do
    <<~MARKDOWN
      ## Complete Guide to Testing

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
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")
  end

  describe "creating a comment via the form" do
    it "creates a thread with correct anchor position" do
      visit plan_page_path(plan)
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

      expect(page).not_to have_css("#new-comment-form", visible: true)

      thread = plan.comment_threads.reload.last
      expect(thread).to be_present
      expect(thread.anchor_text).to eq("Complete")
      expect(thread.anchor_start).to eq(plan_content.index("Complete"))
      expect(thread.anchor_occurrence_index).to eq(0)
    end
  end

  describe "selecting repeated visible text" do
    let(:plan_content) do
      <<~MARKDOWN
        # Repeated words

        <!-- notes: the hidden speaker notes mention the old diagram. -->

        [Background](https://example.com/the)

        Read **the** foundations.

        Read the carts.
      MARKDOWN
    end

    it "keeps the selected occurrence after posting and reloading" do
      visit plan_page_path(plan)
      expect(page).to have_content("Read the carts.")

      # Select the real DOM word and use the public shortcut, exercising
      # selection capture and occurrence counting as well as server resolution.
      page.execute_script <<~JS
        const paragraph = Array.from(document.querySelectorAll('#plan-content-body p'))
          .find(p => p.textContent === 'Read the carts.');
        const range = document.createRange();
        range.setStart(paragraph.firstChild, 5);
        range.setEnd(paragraph.firstChild, 8);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      JS
      find("body").send_keys("c")
      within("#new-comment-form") do
        fill_in "comment_thread[body_markdown]", with: "Feedback about carts."
        click_button "Comment"
      end

      expect(page).not_to have_css("#new-comment-form", visible: true)
      thread = plan.comment_threads.reload.sole
      expect(thread.anchor_start).to eq(plan_content.index("the carts"))
      selector = "p mark[data-thread-id='comment_thread_#{thread.id}']"
      expect(page).to have_css(selector, text: "the", count: 1)
      expect(find(selector).find(:xpath, "..").text).to eq("Read the carts.")

      visit plan_page_path(plan, thread: thread.id)
      expect(page).to have_css(selector, text: "the", count: 1)
      expect(find(selector).find(:xpath, "..").text).to eq("Read the carts.")
      expect(page).to have_css(".thread-popover:popover-open", text: "Feedback about carts.")
      find(".thread-popover:popover-open .comment-window__move").send_keys(*Array.new(18, :arrow_right))
      %w[light dark].each do |theme|
        page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: theme } ])
        expect(page).to have_css(selector, text: "the", count: 1)
        page.save_screenshot(Rails.root.join("tmp/screenshots/comment-anchor-#{theme}.png"))
      end
    end
  end

  describe "selecting text in an editor preview" do
    let(:plan_content) do
      "# Preview words\n\n<!-- notes: Target -->\n\n| Heading |\n| --- |\n| Target |\n"
    end

    it "preserves the preview's source occurrence rather than treating it as a reader occurrence" do
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".ProseMirror .document-editor__block-preview td", text: "Target", wait: 20)
      page.execute_script <<~JS
        const cell = document.querySelector('.ProseMirror .document-editor__block-preview td');
        const range = document.createRange();
        range.selectNodeContents(cell);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        document.querySelector('.document-editor__paper').dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
      JS
      within(".comment-popover") { click_button "Comment" }
      within("#new-comment-form") do
        fill_in "comment_thread[body_markdown]", with: "Preview feedback."
        click_button "Comment"
      end
      expect(page).not_to have_css("#new-comment-form", visible: true)
      thread = plan.comment_threads.reload.sole
      expect(thread.anchor_start).to eq(plan_content.rindex("Target"))
      expect(page).to have_css(".document-editor__block-preview mark[data-thread-id='comment_thread_#{thread.id}']", text: "Target")
    end
  end

  describe "selecting Markdown source" do
    let(:plan_content) { "# Raw words\n\n<!-- **world** -->\n\nHello **world** today.\n" }

    it "keeps Markdown syntax and source-relative occurrences in the Raw pane" do
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".ProseMirror", wait: 20)
      click_button "Raw", exact: true
      expect(page).to have_css(".document-editor__raw .ProseMirror")
      page.execute_script <<~JS
        const root = document.querySelector('.document-editor__raw .ProseMirror');
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          const start = node.textContent.indexOf('Hello **world**');
          if (start < 0) continue;
          const range = document.createRange();
          range.setStart(node, start + 6);
          range.setEnd(node, start + 15);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          break;
        }
        document.querySelector('.document-editor__paper').dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
      JS
      within(".comment-popover") { click_button "Comment" }
      within("#new-comment-form") do
        fill_in "comment_thread[body_markdown]", with: "Raw source feedback."
        click_button "Comment"
      end
      expect(page).not_to have_css("#new-comment-form", visible: true)
      thread = plan.comment_threads.reload.sole
      expect(thread.anchor_text).to eq("**world**")
      expect(thread.anchor_start).to eq(plan_content.rindex("**world**"))
    end
  end

  describe "selecting rich-editor text beside editable math" do
    let(:plan_content) { "# Math words\n\nThe formula $x$ uses x.\n" }

    it "keeps the editor's source occurrence when TeX is editable" do
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".document-editor__body .ProseMirror", wait: 20)
      page.execute_script <<~JS
        const root = document.querySelector('.document-editor__body .ProseMirror');
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          if (!node.textContent.includes(' uses x.')) continue;
          const start = node.textContent.lastIndexOf('x');
          const range = document.createRange();
          range.setStart(node, start);
          range.setEnd(node, start + 1);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          break;
        }
        document.querySelector('.document-editor__paper').dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
      JS
      within(".comment-popover") { click_button "Comment" }
      within("#new-comment-form") do
        fill_in "comment_thread[body_markdown]", with: "Text beside math."
        click_button "Comment"
      end
      expect(page).not_to have_css("#new-comment-form", visible: true)
      expect(plan.comment_threads.reload.sole.anchor_start).to eq(plan_content.rindex("x."))
    end
  end
end
