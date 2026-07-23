require "rails_helper"

RSpec.describe "Human plan editing", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Editable Plan", visibility: "published", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: "# Editable Plan\n\nFirst draft body.\n",
      actor_type: "human", actor_id: author.id
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

  before { sign_in(author) }

  it "edits plan content through the web editor" do
    visit plan_path(plan)
    find("a[aria-label='Edit plan']").click

    expect(page).to have_field("content", with: /First draft body/)

    fill_in "content", with: "# Editable Plan\n\nRevised body from the browser.\n"
    fill_in "change_summary", with: "Browser edit"
    click_button "Save new version"

    expect(page).to have_content("Plan updated.")
    expect(page).to have_content("Revised body from the browser.")

    plan.reload
    expect(plan.current_revision).to eq(2)
    expect(plan.current_plan_version.actor_type).to eq("human")
    expect(plan.current_plan_version.change_summary).to eq("Browser edit")
  end

  it "edits title and tags through the unified editor" do
    plan.tag_names = ["security"]
    plan.save!

    visit edit_content_plan_path(plan)
    fill_in "Title", with: "Renamed In Editor"
    # Tag chips: type a tag and press Enter to commit it as a chip. Wait for
    # the existing tag's chip first — it only renders once the Stimulus
    # controller connects, and before that Enter isn't intercepted and would
    # natively submit the form mid-keystroke.
    expect(page).to have_css(".tag-input__chip", text: "security")
    find("#plan_tag_field").send_keys("api-design", :enter)
    click_button "Save new version"

    expect(page).to have_content("Plan updated.")
    plan.reload
    expect(plan.title).to eq("Renamed In Editor")
    expect(plan.tag_names).to contain_exactly("security", "api-design")
  end

  it "previews markdown before saving" do
    visit edit_content_plan_path(plan)

    fill_in "content", with: "# Preview me\n\n**bold text**\n"
    click_button "Preview"

    expect(page).to have_css("strong", text: "bold text")

    click_button "Write"
    expect(page).to have_field("content", with: /Preview me/)
  end

  it "toggles visibility with one labeled click each way, no reload" do
    plan.update!(visibility: "draft")
    visit plan_path(plan)

    expect(page).to have_css(".visibility-toggle", text: "Private")
    find(".visibility-toggle").click
    expect(page).to have_css(".visibility-toggle", text: "Shared", wait: 5)
    expect(page).to have_content("Shared with everyone in the org.")
    expect(plan.reload.visibility).to eq("published")

    # And back — hiding a shared plan is allowed, same single click. The
    # server Turbo Stream replaces the header, so re-find the button.
    find(".visibility-toggle").click
    expect(page).to have_css(".visibility-toggle--hidden", text: "Private", wait: 5)
    expect(page).to have_content("Private again — hidden from lists and search.")
    expect(plan.reload.visibility).to eq("draft")
  end

  it "keeps the visibility button in sync when the header is replaced externally" do
    plan.update!(visibility: "draft")
    visit plan_path(plan)
    expect(page).to have_css(".visibility-toggle--hidden", text: "Private")

    # An API publish or another tab's toggle reaches this page as a
    # broadcast replacing #plan-header with a re-render that carries the new
    # state flag. Simulate that replacement and check the button follows.
    page.execute_script(<<~JS)
      const header = document.getElementById("plan-header")
      const fresh = header.cloneNode(true)
      fresh.dataset.planVisibility = "published"
      header.replaceWith(fresh)
    JS

    expect(page).to have_css(".visibility-toggle", text: "Shared", wait: 5)
    expect(page).not_to have_css(".visibility-toggle--hidden")
  end

  it "archives and restores the plan" do
    visit plan_path(plan)

    click_button "Archive"
    expect(page).to have_content("Plan archived.")
    expect(plan.reload.archived?).to be(true)

    click_button "Restore"
    expect(page).to have_content("Plan restored.")
    expect(plan.reload.archived?).to be(false)
  end

  it "hides owner controls from non-authors" do
    other = create(:coplan_user, email: "viewer@example.com")
    click_link "Sign out"
    sign_in(other)

    visit plan_path(plan)
    expect(page).to have_content("Editable Plan")
    expect(page).not_to have_css("a[aria-label='Edit plan']")
    expect(page).not_to have_button("Archive")
    expect(page).not_to have_css(".visibility-toggle")
  end
end
