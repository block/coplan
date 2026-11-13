require "rails_helper"

RSpec.describe "Interactive checkboxes", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }

  let(:plan_content) do
    <<~MARKDOWN
      ## Launch Checklist

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
    expect(page).to have_button("Menu")
  end

  before { sign_in(author) }

  it "renders task list items as interactive checkboxes" do
    visit plan_page_path(plan)

    checkboxes = all('input[type="checkbox"]')
    expect(checkboxes.length).to eq(4)

    expect(checkboxes[0]).not_to be_checked
    expect(checkboxes[1]).not_to be_checked
    expect(checkboxes[2]).to be_checked
    expect(checkboxes[3]).not_to be_checked
  end

  it "renders checkboxes without the disabled attribute" do
    visit plan_page_path(plan)

    disabled_values = page.evaluate_script(
      'Array.from(document.querySelectorAll(\'input[type="checkbox"]\')).map(cb => cb.disabled)'
    )
    disabled_values.each do |val|
      expect(val).to be false
    end
  end

  it "adds task-list-item class to checkbox list items" do
    visit plan_page_path(plan)

    expect(page).to have_css("li.task-list-item", minimum: 4)
  end

  it "names each checkbox after its task text" do
    visit plan_page_path(plan)

    expect(page).to have_unchecked_field("Task: Write documentation", type: "checkbox", enable_aria_label: true)
  end

  it "checks an unchecked checkbox and creates a new version" do
    visit plan_page_path(plan)

    initial_version_count = CoPlan::PlanVersion.count

    checkbox = find_field("Task: Write documentation", type: "checkbox", enable_aria_label: true)
    expect(checkbox).not_to be_checked

    checkbox.click
    # The saved version can replace the body; assert against the current field.
    expect(page).to have_checked_field("Task: Write documentation", type: "checkbox", enable_aria_label: true)

    # Wait for the server response by checking the version was created
    wait_for_version(plan, 2)

    plan.reload
    expect(plan.current_content).to include("- [x] Write documentation")
    expect(CoPlan::PlanVersion.count).to eq(initial_version_count + 1)

    version = plan.current_plan_version
    expect(version.actor_id).to eq(author.id)
    expect(version.change_summary).to eq("Toggle checkbox")
    snapshot = version.writing_provenance
    expect(snapshot.dig("summary", "counts", "human")).to eq(1)
    expect(snapshot.fetch("sources").values).to include(a_hash_including("kind" => "human", "user_id" => author.id, "origin_revision" => 2))
  end

  it "unchecks a checked checkbox" do
    visit plan_page_path(plan)

    checkbox = find_field("Task: Set up monitoring", type: "checkbox", enable_aria_label: true)
    expect(checkbox).to be_checked

    checkbox.click
    expect(page).to have_unchecked_field("Task: Set up monitoring", type: "checkbox", enable_aria_label: true)

    wait_for_version(plan, 2)

    plan.reload
    expect(plan.current_content).to include("- [ ] Set up monitoring")
  end

  it "updates data-line-text after toggling" do
    visit plan_page_path(plan)

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
    visit plan_page_path(plan)

    first_cb = all('input[type="checkbox"]')[0]
    first_cb.click
    wait_for_version(plan, 2)
    # The version bump broadcasts a whole-body re-render (Broadcaster
    # .replace_plan_content) that the DB poll above can't see. Grab the
    # second checkbox only after the swap lands, or the handle can detach
    # between find and click.
    wait_for_content_refresh(2)
    expect(page).to have_css("h2 .section-permalink", visible: :all)

    second_cb = all('input[type="checkbox"]')[1]
    second_cb.click
    wait_for_version(plan, 3)

    plan.reload
    expect(plan.current_revision).to eq(3)
    expect(plan.current_content).to include("- [x] Write documentation")
    expect(plan.current_content).to include("- [x] Run load tests")
  end

  it "does not toggle the checkbox when the task text is clicked" do
    visit plan_page_path(plan)
    count_toggle_requests

    find("li.task-list-item .task-list-item-content", text: "Write documentation").click

    expect(page).to have_unchecked_field("Task: Write documentation", type: "checkbox", enable_aria_label: true)
    expect(page.evaluate_script("window.toggleRequests")).to eq(0)
  end

  it "does not toggle the checkbox when a word in the task text is double-clicked" do
    set_version_fixture(plan.current_plan_version, content_markdown: "# Tasks\n\n- [ ] Review `retry_policy` settings")
    visit plan_page_path(plan)
    count_toggle_requests

    find("li.task-list-item .task-list-item-content code", text: "retry_policy").double_click

    expect(page.evaluate_script("window.getSelection().toString()")).to include("retry_policy")
    expect(page).to have_unchecked_field("Task: Review retry_policy settings", type: "checkbox", enable_aria_label: true)
    expect(page.evaluate_script("window.toggleRequests")).to eq(0)
  end

  it "toggles the checkbox from the padded hit area around the box" do
    visit plan_page_path(plan)

    hit_area = find("li.task-list-item label.task-list-item-checkbox", match: :first)
    hit_area.click(x: -hit_area.native.size.width / 2 + 1, y: -hit_area.native.size.height / 2 + 1)

    expect(page).to have_checked_field("Task: Write documentation", type: "checkbox", enable_aria_label: true)
    wait_for_version(plan, 2)
    expect(plan.reload.current_content).to include("- [x] Write documentation")
  end

  it "toggles the correct checkbox when task lines are duplicated" do
    set_version_fixture(plan.current_plan_version,
      content_markdown: "# Tasks\n\n- [ ] TODO\n- [ ] TODO\n- [ ] Deploy\n- [ ] Deploy to staging"
    )

    visit plan_page_path(plan)

    checkboxes = all('input[type="checkbox"]')
    checkboxes[1].click

    wait_for_version(plan, 2)

    plan.reload
    expect(plan.current_content).to eq("# Tasks\n\n- [ ] TODO\n- [x] TODO\n- [ ] Deploy\n- [ ] Deploy to staging")
  end

  it "toggles a task whose text is a prefix of another task" do
    set_version_fixture(plan.current_plan_version,
      content_markdown: "# Tasks\n\n- [ ] Deploy to staging\n- [ ] Deploy"
    )

    visit plan_page_path(plan)

    checkboxes = all('input[type="checkbox"]')
    checkboxes[1].click

    wait_for_version(plan, 2)

    plan.reload
    expect(plan.current_content).to eq("# Tasks\n\n- [ ] Deploy to staging\n- [x] Deploy")
  end

  private

  # The live-update broadcast replaces the children of #plan-content-body and
  # stamps the new revision on it — waiting for the stamp is the only
  # race-free way to know the swap has already happened.
  def wait_for_content_refresh(revision)
    expect(page).to have_css(
      "#plan-content-body[data-coplan--live-update-revision-value='#{revision}']"
    )
  end

  # The checkbox controller sends its PATCH synchronously from its event
  # handler, so a zero count right after a gesture means no toggle fired.
  def count_toggle_requests
    page.execute_script(<<~JS)
      window.toggleRequests = 0
      const originalFetch = window.fetch
      window.fetch = (url, options = {}) => {
        if (options.method === "PATCH") window.toggleRequests += 1
        return originalFetch(url, options)
      }
    JS
  end

  def wait_for_version(plan, expected_revision, timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        break if plan.class.find(plan.id).current_revision >= expected_revision
        sleep 0.1
      end
    end
  end
end
