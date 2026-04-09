require "rails_helper"

RSpec.describe "Interactive checkboxes", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }

  let(:plan_content) do
    <<~MARKDOWN
      # Launch Checklist

      - [ ] Write documentation
      - [ ] Run load tests
      - [x] Set up monitoring
      - [ ] Get security review
    MARKDOWN
  end

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Checklist Plan", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: plan_content, actor_type: "human", actor_id: author.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_content("Sign out")
  end

  before { sign_in(author) }

  it "renders task list items as interactive checkboxes" do
    visit plan_path(plan)

    checkboxes = all('input[type="checkbox"]')
    expect(checkboxes.length).to eq(4)

    expect(checkboxes[0]).not_to be_checked
    expect(checkboxes[1]).not_to be_checked
    expect(checkboxes[2]).to be_checked
    expect(checkboxes[3]).not_to be_checked
  end

  it "renders checkboxes without the disabled attribute" do
    visit plan_path(plan)

    disabled_values = page.evaluate_script(
      'Array.from(document.querySelectorAll(\'input[type="checkbox"]\')).map(cb => cb.disabled)'
    )
    disabled_values.each do |val|
      expect(val).to be false
    end
  end

  it "adds task-list-item class to checkbox list items" do
    visit plan_path(plan)

    expect(page).to have_css("li.task-list-item", minimum: 4)
  end

  it "wraps checkbox items in labels for full-text clickability" do
    visit plan_path(plan)

    expect(page).to have_css("li.task-list-item label input[type='checkbox']", minimum: 4)
  end

  it "checks an unchecked checkbox and creates a new version" do
    visit plan_path(plan)

    initial_version_count = CoPlan::PlanVersion.count

    # Find the first unchecked checkbox ("Write documentation")
    checkbox = all('input[type="checkbox"]').first
    expect(checkbox).not_to be_checked

    checkbox.click
    expect(checkbox).to be_checked

    # Wait for the server response by checking the version was created
    wait_for_version(plan, 2)

    plan.reload
    expect(plan.current_content).to include("- [x] Write documentation")
    expect(CoPlan::PlanVersion.count).to eq(initial_version_count + 1)

    version = plan.current_plan_version
    expect(version.actor_id).to eq(author.id)
    expect(version.change_summary).to eq("Toggle checkbox")
  end

  it "unchecks a checked checkbox" do
    visit plan_path(plan)

    checkbox = find('input[type="checkbox"][checked]')
    expect(checkbox).to be_checked

    checkbox.click
    expect(checkbox).not_to be_checked

    wait_for_version(plan, 2)

    plan.reload
    expect(plan.current_content).to include("- [ ] Set up monitoring")
  end

  it "updates data-line-text after toggling" do
    visit plan_path(plan)

    checkbox = all('input[type="checkbox"]').first
    expect(checkbox["data-line-text"]).to eq("- [ ] Write documentation")

    checkbox.click

    wait_for_version(plan, 2)

    updated_line_text = page.evaluate_script(
      'document.querySelector(\'input[type="checkbox"]\').dataset.lineText'
    )
    expect(updated_line_text).to eq("- [x] Write documentation")
  end

  it "supports toggling multiple checkboxes in sequence" do
    visit plan_path(plan)

    first_cb = all('input[type="checkbox"]')[0]
    first_cb.click
    wait_for_version(plan, 2)

    second_cb = all('input[type="checkbox"]')[1]
    second_cb.click
    wait_for_version(plan, 3)

    plan.reload
    expect(plan.current_revision).to eq(3)
    expect(plan.current_content).to include("- [x] Write documentation")
    expect(plan.current_content).to include("- [x] Run load tests")
  end

  it "toggles checkbox by clicking the label text" do
    visit plan_path(plan)

    label = find("li.task-list-item label", text: "Write documentation")
    label.click

    wait_for_version(plan, 2)

    plan.reload
    expect(plan.current_content).to include("- [x] Write documentation")
  end

  private

  def wait_for_version(plan, expected_revision, timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        break if plan.class.find(plan.id).current_revision >= expected_revision
        sleep 0.1
      end
    end
  end
end
