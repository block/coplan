require "rails_helper"

RSpec.describe CoPlan::Plans::LogEvent do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }

  describe ".call" do
    it "creates a PlanEvent attributed to the actor" do
      expect {
        described_class.call(
          plan: plan,
          actor: user,
          event_type: "status_changed",
          before: "considering",
          after: "developing"
        )
      }.to change { CoPlan::PlanEvent.count }.by(1)

      event = CoPlan::PlanEvent.last
      expect(event.plan).to eq(plan)
      expect(event.actor_user).to eq(user)
      expect(event.actor_type).to eq("human")
      expect(event.event_type).to eq("status_changed")
      expect(event.before_value).to eq("considering")
      expect(event.after_value).to eq("developing")
    end

    it "infers a sensible default field per event_type when not provided" do
      described_class.call(plan: plan, actor: user, event_type: "tag_added", after: "payments")
      expect(CoPlan::PlanEvent.last.field).to eq("tags")
    end

    it "treats the actor as 'system' when no user is passed (e.g. backfill jobs)" do
      described_class.call(plan: plan, actor: nil, event_type: "status_changed", before: "a", after: "b")
      event = CoPlan::PlanEvent.last
      expect(event.actor_type).to eq("system")
      expect(event.actor_id).to be_nil
    end

    it "returns nil and does not persist when before == after for change events" do
      # Call sites should be allowed to fire on every save without checking;
      # the service no-ops when nothing actually changed.
      expect {
        described_class.call(plan: plan, actor: user, event_type: "status_changed", before: "considering", after: "considering")
      }.not_to change { CoPlan::PlanEvent.count }
    end

    it "still records add/remove events even when one side is nil" do
      described_class.call(plan: plan, actor: user, event_type: "tag_added", after: "payments")
      described_class.call(plan: plan, actor: user, event_type: "reference_removed", before: "https://x")
      expect(CoPlan::PlanEvent.count).to eq(2)
    end

    it "passes through structured metadata" do
      described_class.call(
        plan: plan,
        actor: user,
        event_type: "reference_added",
        after: "https://github.com/example/repo",
        metadata: { title: "Example", reference_type: "repository" }
      )
      event = CoPlan::PlanEvent.last
      expect(event.metadata).to include("title" => "Example", "reference_type" => "repository")
    end

    it "coerces non-string before/after values to strings for storage" do
      described_class.call(plan: plan, actor: user, event_type: "tag_added", after: 42)
      expect(CoPlan::PlanEvent.last.after_value).to eq("42")
    end
  end
end
