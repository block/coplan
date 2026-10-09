require "rails_helper"

# The one-time "changed since you last looked" highlight: the plan page
# embeds the changed section keys for the changed-sections Stimulus
# controller, and the same request advances last_seen_at so a reload
# shows nothing.
RSpec.describe "Changed-section highlights", type: :request do
  let(:author) { create(:coplan_user) }
  let(:viewer) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: author) }

  def keys_attr(body)
    body[/data-coplan--changed-sections-keys-value="([^"]*)"/, 1]
  end

  def rewritten_attr(body)
    body[/data-coplan--changed-sections-rewritten-value="([^"]*)"/, 1]
  end

  it "sends no keys on a first-ever visit" do
    sign_in_as(viewer)
    get plan_page_path(plan)

    expect(response).to have_http_status(:ok)
    expect(keys_attr(response.body)).to eq("[]")
  end

  it "highlights changed sections once, then clears on the next visit" do
    plan.current_plan_version.update_columns(created_at: 2.hours.ago)
    CoPlan::PlanViewer.create!(plan: plan, user: viewer, last_seen_at: 1.hour.ago)

    v2 = create(:plan_version, plan: plan, revision: 2, actor_id: author.id,
      content_markdown: "# Plan Content\n\nSome content here, freshly edited.")
    plan.update_columns(current_plan_version_id: v2.id, current_revision: 2)

    sign_in_as(viewer)
    get plan_page_path(plan)
    expect(keys_attr(response.body)).to include("plan-content")

    # That request advanced last_seen_at — the highlight is spent.
    get plan_page_path(plan)
    expect(keys_attr(response.body)).to eq("[]")
  end

  it "compares against the most recent version the viewer read, without repeating older changes" do
    original = "## Design\n\nOriginal design.\n\n## Rollout\n\nOriginal rollout.\n"
    plan.current_plan_version.update_columns(content_markdown: original, created_at: 1.hour.ago)
    read_version = create(:plan_version, plan: plan, revision: 2, actor_id: author.id,
      content_markdown: original.sub("Original design", "Revised design"), created_at: 30.minutes.ago)
    latest = create(:plan_version, plan: plan, revision: 3, actor_id: author.id,
      content_markdown: read_version.content_markdown.sub("Original rollout", "Revised rollout"), created_at: 5.minutes.ago)
    plan.update!(current_plan_version: latest, current_revision: 3)
    CoPlan::PlanViewer.create!(plan: plan, user: viewer, last_seen_at: 10.minutes.ago)

    sign_in_as(viewer)
    get plan_page_path(plan)

    html = Nokogiri::HTML(response.body)
    expect(JSON.parse(html.at_css(".plan-layout")["data-coplan--changed-sections-keys-value"])).to eq([ "rollout" ])
    updates = JSON.parse(html.at_css(".plan-layout")["data-coplan--changed-sections-updates-value"])
    expect(updates.keys).to eq([ "rollout" ])
    expect(updates["rollout"]["revision"]).to eq(3)
  end

  it "embeds the last section editor and time safely, with simple history and dismiss controls" do
    author.update!(name: 'Editor "<design>"')
    original = "## Design\n\nOriginal design.\n\n## Rollout\n\nOriginal rollout.\n"
    plan.current_plan_version.update_columns(content_markdown: original, created_at: 2.hours.ago)
    CoPlan::PlanViewer.create!(plan: plan, user: viewer, last_seen_at: 1.hour.ago)
    edited = create(:plan_version, plan: plan, revision: 2, actor_id: author.id,
      actor_type: "local_agent", agent_name: "Codex", created_at: 30.minutes.ago,
      content_markdown: original.sub("Original design", "Revised design"))
    latest = create(:plan_version, plan: plan, revision: 3, actor_id: viewer.id,
      content_markdown: edited.content_markdown.sub("Original rollout", "Revised rollout"))
    plan.update!(current_plan_version: latest, current_revision: 3)

    sign_in_as(viewer)
    get plan_page_path(plan)
    html = Nokogiri::HTML(response.body)
    updates = JSON.parse(html.at_css(".plan-layout")["data-coplan--changed-sections-updates-value"])
    expect(updates["design"]).to include("by" => 'Codex (via Editor "<design>")', "at" => edited.created_at.iso8601)
    expect(updates["rollout"]).to include("by" => viewer.name, "at" => latest.created_at.iso8601)
    expect(html.at_css(".changed-sections-note").text).to include("History", "Dismiss")
    expect(html.at_css(".changed-sections-note").text).not_to include("Review updates", "Next", "Previous")
  end

  it "sends no keys when nothing changed since the last visit" do
    sign_in_as(viewer)
    get plan_page_path(plan)
    get plan_page_path(plan)

    expect(keys_attr(response.body)).to eq("[]")
  end

  # The agent filled in a plan you'd only glanced at: nothing to point at,
  # so the page gets the rewrite flag and no keys.
  it "flags a rewrite instead of sending keys when most of the plan changed" do
    plan.current_plan_version.update_columns(created_at: 2.hours.ago)
    CoPlan::PlanViewer.create!(plan: plan, user: viewer, last_seen_at: 1.hour.ago)

    v2 = create(:plan_version, plan: plan, revision: 2, actor_id: author.id,
      content_markdown: (1..5).map { |i| "## Part #{i}\n\nFreshly written body #{i}.\n" }.join("\n"))
    plan.update_columns(current_plan_version_id: v2.id, current_revision: 2)

    sign_in_as(viewer)
    get plan_page_path(plan)

    expect(keys_attr(response.body)).to eq("[]")
    expect(rewritten_attr(response.body)).to eq("true")
  end

  it "does not flag a rewrite when there is nothing new at all" do
    sign_in_as(viewer)
    get plan_page_path(plan)

    expect(rewritten_attr(response.body)).to eq("false")
  end
end
