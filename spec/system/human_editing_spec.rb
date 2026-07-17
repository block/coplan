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
    click_link "Edit content"

    expect(page).to have_field("content", with: /First draft body/)

    fill_in "content", with: "# Editable Plan\n\nRevised body from the browser.\n"
    fill_in "change_summary", with: "Browser edit"
    click_button "Save new version"

    expect(page).to have_content("Plan content updated.")
    expect(page).to have_content("Revised body from the browser.")

    plan.reload
    expect(plan.current_revision).to eq(2)
    expect(plan.current_plan_version.actor_type).to eq("human")
    expect(plan.current_plan_version.change_summary).to eq("Browser edit")
  end

  it "previews markdown before saving" do
    visit edit_content_plan_path(plan)

    fill_in "content", with: "# Preview me\n\n**bold text**\n"
    click_button "👁 Preview"

    expect(page).to have_css("strong", text: "bold text")

    click_button "✏️ Write"
    expect(page).to have_field("content", with: /Preview me/)
  end

  it "publishes a draft from the plan page" do
    plan.update!(visibility: "draft")
    visit plan_path(plan)

    accept_confirm { click_button "Publish" }

    expect(page).to have_content("Plan published — everyone can see it now.")
    expect(plan.reload.visibility).to eq("published")
    expect(page).not_to have_button("Publish")
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
    expect(page).not_to have_link("Edit content")
    expect(page).not_to have_button("Archive")
    expect(page).not_to have_button("Publish")
  end
end
