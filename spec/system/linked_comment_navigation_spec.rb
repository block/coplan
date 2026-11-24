require "rails_helper"

RSpec.describe "Linked comment navigation", type: :system do
  let(:author) { create(:coplan_user, email: "linked-comment-author@example.com") }
  let(:plan) { create(:plan, created_by_user: author) }

  %w[light dark].each do |theme|
    [ "inline", "document", "earlier text", "resolved earlier text" ].each do |kind|
      it "keeps the linked #{kind} discussion open after rendering in #{theme} mode" do
        author.update!(theme_preference: theme)
        version = plan.current_plan_version
        set_version_fixture(version, content_markdown: "# Review\n\nThe retry budget needs review.")
        thread = plan.comment_threads.create!(plan_version: version, created_by_user: author,
          anchor_text: kind == "document" ? nil : "retry budget", anchor_occurrence: 1)
        thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Can we extend the retry window?")
        thread.update!(out_of_date: true, out_of_date_since_version: version) if kind.include?("earlier text")
        thread.resolve!(author) if kind.start_with?("resolved")

        visit sign_in_path
        fill_in "Email address", with: author.email
        click_button "Sign In"
        expect(page).to have_current_path(library_page_path(author))

        visit plan_page_path(plan, thread: thread.id)
        popover = "#comment_thread_#{thread.id}_popover:popover-open"
        expect(page).to have_css(popover, text: "Can we extend the retry window?")

        # Async renderers announce this after rewriting the document DOM.
        # The linked discussion must remain readable through every refresh.
        2.times do
          page.execute_script(<<~JS)
            document.querySelector("#plan-content-body").dispatchEvent(
              new CustomEvent("coplan:highlight-settled", { bubbles: true })
            )
          JS
          expect(page).to have_css(popover, text: "Can we extend the retry window?")
        end

        if thread.open?
          within(popover) { find("textarea").fill_in(with: "I can still reply.") }
          expect(page).to have_field(with: "I can still reply.")
        end
        page.save_screenshot(Rails.root.join("tmp/linked-comments/#{kind.tr(' ', '-')}-#{theme}.png"))

        page.driver.browser.action.send_keys(:escape).perform
        expect(page).to have_no_css(popover)
        page.execute_script(<<~JS)
          document.querySelector("#plan-content-body").dispatchEvent(
            new CustomEvent("coplan:highlight-settled", { bubbles: true })
          )
        JS
        expect(page).to have_no_css(popover)
      end
    end
  end
end
