require "rails_helper"

RSpec.describe "Bell notification navigation", type: :system do
  let(:reviewer) { create(:coplan_user, email: "bell-reviewer@example.com") }
  let(:plan) { create(:plan, :published, title: "Approval navigation example") }
  let!(:request) { create(:review_request, plan: plan, reviewer: reviewer) }

  %w[light dark].each do |theme|
    [ "task", "review_requested", "review_response" ].each do |entry|
      it "opens the plan from the #{entry} bell entry in #{theme} mode" do
        reviewer.update!(theme_preference: theme)
        notification = if entry != "task"
          create(:notification, user: reviewer, plan: plan, comment_thread: nil,
            review_request: request, reason: entry)
        end

        visit sign_in_path
        fill_in "Email address", with: reviewer.email
        click_button "Sign In"
        expect(page).to have_link("Go to your library", wait: 10)
        visit notifications_path
        page.execute_script("window.bellNavigationMarker = true")
        click_button "Notifications", exact: true, enable_aria_label: true

        within(".inbox-panel") do
          link = if notification
            find("#notification_#{notification.id} a")
          else
            find(".review-tasks__item", text: plan.title)
          end
          # Wait for a real hover response before checking unread state. The
          # subsequent click must use Turbo's cached HTML and still acknowledge
          # the notification through the plan's presence subscription.
          page.execute_script(<<~JS, plan_page_path(plan))
            document.addEventListener("turbo:before-fetch-response", event => {
              const response = event.detail.fetchResponse.response
              if (new URL(response.url).pathname === arguments[0] && response.ok) {
                event.target.dataset.bellPrefetched = "true"
              }
            })
          JS
          link.hover
          expect(page).to have_css('a[data-bell-prefetched="true"]')
          expect(notification.reload).not_to be_read if notification
          link.click
        end

        expect(page).to have_current_path(plan_page_path(plan), wait: 10)
        expect(page).to have_css("#plan-review-controls")
        expect(page).to have_no_text("Content missing")
        expect(page.evaluate_script("window.bellNavigationMarker")).to eq(true)
        expect(page.evaluate_script(<<~JS, plan_page_path(plan))).to eq(1)
          performance.getEntriesByName(new URL(arguments[0], location.origin).href)
            .filter(entry => entry.initiatorType === "fetch").length
        JS
        expect(page).to have_css("#inbox-badge.inbox-badge--hidden", visible: :all)
        expect(notification.reload).to be_read if notification
        expect(request.reload).to be_pending
        page.save_screenshot(Rails.root.join("tmp/bell-navigation/#{entry}-#{theme}.png"))
      end
    end
  end
end
