require "rails_helper"

RSpec.describe "Viewer stack in the sticky nav", type: :system do
  let(:user) { create(:coplan_user, name: "Alex Morgan", email: "alex@example.com") }
  let(:plan) { create(:plan, :published, created_by_user: user, title: "Long presence review") }

  def sign_in
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
  end

  def nav_controls_box
    page.evaluate_script(<<~JS)
      [".site-nav", ".site-nav__search", ".site-nav__bell", ".site-nav__menu-btn"].map(selector => {
        const rect = document.querySelector(selector).getBoundingClientRect()
        return [rect.left, rect.top, rect.width, rect.height].map(Math.round)
      })
    JS
  end

  before do
    plan.current_plan_version.update!(
      content_markdown: (1..30).map { |n| "## Section #{n}\n\nEnough content to scroll past the masthead." }.join("\n\n")
    )
    sign_in
    visit plan_page_path(plan)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    expect(page).to have_css("#plan-viewers .plan-viewers__avatar", text: "AM")
  end

  it "fades in once the header scrolls away and follows presence broadcasts" do
    expect(page).to have_css("#plan-nav-viewers", visible: :hidden)
    at_top = nav_controls_box

    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")

    expect(page).to have_css(".site-nav__plan-context--visible")
    within("#plan-nav-viewers") do
      expect(page).to have_link(href: library_page_path(user), visible: true)
      expect(page).to have_css(".plan-viewers__avatar", text: "AM")
      expect(page).to have_no_css(".plan-viewers__label", visible: true)
    end
    expect(nav_controls_box).to eq(at_top)

    # A second person opens the plan, and the next ping rebroadcasts the list.
    create(:plan_viewer, plan: plan, user: create(:coplan_user, name: "Sam Rivera"))
    page.execute_script(<<~JS)
      const masthead = document.querySelector(".plan-masthead")
      window.Stimulus.getControllerForElementAndIdentifier(masthead, "coplan--presence").channel.perform("ping")
    JS

    expect(page).to have_css("#plan-nav-viewers .plan-viewers__avatar", text: "SR", visible: true)
    expect(page).to have_css("#plan-viewers .plan-viewers__label", text: "2 viewing", visible: :all)
    expect(nav_controls_box).to eq(at_top)

    page.execute_script("window.scrollTo(0, 0)")
    expect(page).to have_css("#plan-nav-viewers", visible: :hidden)
  end

  it "shows at most four avatars and an overflow count" do
    6.times { |n| create(:plan_viewer, plan: plan, user: create(:coplan_user, name: "Viewer #{n}")) }
    visit plan_page_path(plan)
    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")

    within("#plan-nav-viewers") do
      expect(page).to have_css(".plan-viewers__avatar-link", count: 4, visible: true)
      expect(page).to have_css(".plan-viewers__overflow", text: "+3", count: 1, visible: true)
    end
    within("#plan-viewers") do
      expect(page).to have_css(".plan-viewers__avatar-link", count: 7, visible: :all)
      expect(page).to have_no_css(".plan-viewers__overflow", visible: true)
    end
  end
end
