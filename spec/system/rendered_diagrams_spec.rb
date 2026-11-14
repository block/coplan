require "rails_helper"

RSpec.describe "Rendered diagram discussions", type: :system do
  let(:user) { create(:coplan_user, email: "diagram-reader@example.com") }
  let(:plan) do
    CoPlan::Plans::Create.call(title: "Diagram", user: user, content: <<~MARKDOWN)
      # Diagram

      ```diagram {skill=graphviz image="/x/diagram.png" lang=dot}
      digraph { client -> server }
      ```
    MARKDOWN
  end
  let!(:thread) do
    plan.comment_threads.create!(plan_version: plan.current_plan_version, anchor_text: "client -> server",
      anchor_occurrence: 1, created_by_user: user, status: "open").tap do |thread|
      thread.comments.create!(author_type: "human", author_id: user.id, body_markdown: "Keep this connection.")
    end
  end

  it "unfolds source before keyboard navigation and restores it after a live update" do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
    visit plan_page_path(plan)
    expect(page).to have_css("details.rendered-diagram__source:not([open])")
    page.driver.browser.action.send_keys("j").perform
    expect(page).to have_css("details.rendered-diagram__source[open] mark.anchor-highlight")
    expect(page).to have_css(".thread-popover:popover-open", text: "Keep this connection.")
    # A fresh render folds the source. The existing active discussion must
    # reveal its replacement mark before positioning the popover.
    page.execute_script(<<~JS)
      const body = document.querySelector("#plan-content-body")
      const replacement = body.cloneNode(true)
      replacement.querySelector("details.rendered-diagram__source").open = false
      body.replaceWith(replacement)
    JS
    expect(page).to have_css("details.rendered-diagram__source[open] mark.anchor-highlight")
    expect(page).to have_css(".thread-popover:popover-open", text: "Keep this connection.")
    page.driver.browser.action.send_keys("r").perform
    expect(page).to have_css(".thread-popover:popover-open textarea:focus")
  end
end
