require "rails_helper"

# Integration-level verification that every mutation path that *should* record
# a metadata event actually does. The point isn't to retest the LogEvent
# service (that has its own spec) — it's to lock down the contract between
# the mutation surfaces and the event log so future controllers don't quietly
# drop the wiring.
RSpec.describe "Plan metadata event logging", type: :request do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: user, title: "Original") }

  before { sign_in_as(user) }

  describe "PATCH /plans/:id (web)" do
    it "records a title_changed event when the title moves" do
      expect {
        patch plan_path(plan), params: { plan: { title: "Renamed" } }
      }.to change { plan.plan_events.where(event_type: "title_changed").count }.by(1)

      event = plan.plan_events.where(event_type: "title_changed").last
      expect(event.before_value).to eq("Original")
      expect(event.after_value).to eq("Renamed")
      expect(event.actor_user).to eq(user)
    end
  end

  describe "PATCH /plans/:id/archive and /unarchive (web)" do
    it "records archived and unarchived events" do
      expect {
        patch archive_plan_path(plan)
      }.to change { plan.plan_events.where(event_type: "archived").count }.by(1)

      expect {
        patch unarchive_plan_path(plan)
      }.to change { plan.plan_events.where(event_type: "unarchived").count }.by(1)
    end
  end

  describe "PATCH /plans/:id/publish (web)" do
    it "records a published event when a draft goes live" do
      draft = create(:plan, :draft, created_by_user: user)

      expect {
        patch publish_plan_path(draft)
      }.to change { draft.plan_events.where(event_type: "published").count }.by(1)

      event = draft.plan_events.where(event_type: "published").last
      expect(event.before_value).to eq("draft")
      expect(event.after_value).to eq("published")
    end
  end

  describe "POST /plans/:id/references (web)" do
    it "records a reference_added event with the URL and metadata" do
      expect {
        post plan_references_path(plan), params: {
          reference: { url: "https://github.com/squareup/example", title: "Example" }
        }
      }.to change { plan.plan_events.where(event_type: "reference_added").count }.by(1)

      event = plan.plan_events.where(event_type: "reference_added").last
      expect(event.after_value).to eq("https://github.com/squareup/example")
      expect(event.metadata).to include("title" => "Example")
    end
  end

  describe "DELETE /plans/:id/references/:id (web)" do
    it "records a reference_removed event capturing the original URL" do
      reference = plan.references.create!(url: "https://github.com/squareup/x", title: "X", reference_type: "repository", source: "explicit")

      expect {
        delete plan_reference_path(plan, reference)
      }.to change { plan.plan_events.where(event_type: "reference_removed").count }.by(1)

      event = plan.plan_events.where(event_type: "reference_removed").last
      expect(event.before_value).to eq("https://github.com/squareup/x")
    end
  end

  describe "PATCH /api/v1/plans/:id (API)" do
    let(:raw_token) { CoPlan::ApiToken.generate_token }
    let!(:token) { create(:api_token, user: user, raw_token: raw_token) }
    let(:auth_headers) { { "Authorization" => "Bearer #{raw_token}" } }

    it "records events for title, archival, and tag diffs in a single request" do
      plan.tag_names = ["existing"]

      expect {
        patch "/api/v1/plans/#{plan.id}", params: {
          title: "API-renamed",
          archived: true,
          tags: ["existing", "added"]
        }, headers: auth_headers, as: :json
      }.to change { plan.plan_events.count }.by(3)

      expect(plan.plan_events.pluck(:event_type)).to contain_exactly(
        "title_changed", "archived", "tag_added"
      )
    end

    it "records tag_removed events for tags that disappear from the list" do
      plan.tag_names = ["payments", "billing"]

      expect {
        patch "/api/v1/plans/#{plan.id}", params: {
          tags: ["payments"]
        }, headers: auth_headers, as: :json
      }.to change { plan.plan_events.where(event_type: "tag_removed").count }.by(1)

      removed = plan.plan_events.where(event_type: "tag_removed").last
      expect(removed.before_value).to eq("billing")
    end

    it "records reference_added when a new reference is included in the update payload" do
      expect {
        patch "/api/v1/plans/#{plan.id}", params: {
          references: [{ url: "https://docs.example.com/spec", title: "Spec" }]
        }, headers: auth_headers, as: :json
      }.to change { plan.plan_events.where(event_type: "reference_added").count }.by(1)
    end
  end

  describe "Plan#history_items" do
    it "interleaves content versions and metadata events, newest first" do
      # The :plan factory already creates a revision-1 PlanVersion for us.
      v1 = plan.plan_versions.first
      v1.update_columns(created_at: 3.hours.ago)
      e1 = create(:plan_event, plan: plan, event_type: "status_changed", created_at: 2.hours.ago)
      v2 = create(:plan_version, plan: plan, revision: 2, created_at: 1.hour.ago)

      items = plan.history_items
      expect(items.map(&:id)).to eq([v2.id, e1.id, v1.id])
      expect(items.map(&:history_kind)).to eq([:version, :event, :version])
    end
  end
end
