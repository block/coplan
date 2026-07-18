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

  it "sends no keys on a first-ever visit" do
    sign_in_as(viewer)
    get plan_path(plan)

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
    get plan_path(plan)
    expect(keys_attr(response.body)).to include("plan-content")

    # That request advanced last_seen_at — the highlight is spent.
    get plan_path(plan)
    expect(keys_attr(response.body)).to eq("[]")
  end

  it "sends no keys when nothing changed since the last visit" do
    sign_in_as(viewer)
    get plan_path(plan)
    get plan_path(plan)

    expect(keys_attr(response.body)).to eq("[]")
  end
end
