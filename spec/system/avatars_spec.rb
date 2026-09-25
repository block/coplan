require "rails_helper"

RSpec.describe "User avatars", type: :system do
  let(:user) { create(:coplan_user, name: "Alex Morgan", email: "alex@example.com", avatar_url: "/missing-avatar.png") }
  let(:plan) { create(:plan, :published, created_by_user: user, title: "Avatar fallback review") }

  def sign_in
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
  end

  %w[light dark].each do |theme|
    it "shows initials for failed and missing photos while retaining valid photos in #{theme} mode" do
      user.update!(theme_preference: theme)
      no_photo = create(:coplan_user, name: "Sam Rivera", avatar_url: nil)
      photo = create(:coplan_user, name: "Taylor Chen", avatar_url: "/icon.png")
      sign_in
      [ user, no_photo, photo ].each { |viewer| create(:plan_viewer, plan: plan, user: viewer) }
      visit plan_page_path(plan)

      expect(page).to have_css("html[data-theme='#{theme}']")
      within("#plan-header") do
        expect(page).to have_css(".avatar", text: "AM")
        expect(page).not_to have_css("img", visible: :all)
      end
      within("#plan-viewers") do
        expect(page).to have_css(".plan-viewers__avatar[aria-label='Alex Morgan']", text: "AM")
        expect(page).to have_css("[aria-label='Sam Rivera']", text: "SR")
        expect(page).to have_css("img.avatar__image--loaded", count: 1)
        expect(page).to have_css("img", count: 1, visible: :all)
        image = find("img")
        expect(image.evaluate_script("this.naturalWidth > 0 && getComputedStyle(this).opacity === '1'")).to be(true)
      end

      find(".plan-viewers__avatar-link[aria-label='Alex Morgan’s profile']").click
      expect(page).to have_current_path(library_page_path(user))
      within(".library-header") do
        expect(page).to have_css(".avatar--lg[aria-label='Alex Morgan']", text: "AM")
        expect(page).not_to have_css("img", visible: :all)
      end
    end
  end

  it "handles a failed image that completed before the controller connected" do
    user.update!(avatar_url: "/icon.png")
    sign_in
    visit library_page_path(user)
    image = find(".library-header img.avatar__image--loaded")
    image.execute_script(<<~JS)
      this.removeAttribute('data-controller');
      this.removeAttribute('data-action');
    JS
    image.execute_script("this.src = '/404.html'")
    expect(page).to have_css(".library-header img[src='/404.html']")
    page.document.synchronize(errors: [ RSpec::Expectations::ExpectationNotMetError ]) do
      expect(image.evaluate_script("this.complete && this.naturalWidth === 0")).to be(true)
    end
    image.execute_script("this.setAttribute('data-controller', 'coplan--avatar')")

    expect(page).not_to have_css(".library-header img", visible: :all)
    expect(page).to have_css(".library-header .avatar", text: "AM")
  end

  it "falls back for new viewer images inserted by a Turbo Stream" do
    user.update!(avatar_url: "/icon.png")
    sign_in
    create(:plan_viewer, plan: plan, user: user)
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-viewers img.avatar__image--loaded")
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    dimensions = page.evaluate_script("Array.from(document.querySelectorAll('.plan-viewers__avatar'), el => [el.offsetWidth, el.offsetHeight])")

    user.update!(avatar_url: "/missing-live-avatar.png")
    CoPlan::Broadcaster.replace_to(plan, target: "plan-viewers",
      partial: "coplan/plans/viewers", locals: { viewers: [ user ] })

    expect(page).not_to have_css("#plan-viewers img", visible: :all)
    expect(page).to have_css(".plan-viewers__avatar", text: "AM")
    expect(page.evaluate_script("Array.from(document.querySelectorAll('.plan-viewers__avatar'), el => [el.offsetWidth, el.offsetHeight])")).to eq(dimensions)
  end
end
