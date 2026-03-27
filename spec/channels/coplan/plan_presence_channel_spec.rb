require "rails_helper"

RSpec.describe CoPlan::PlanPresenceChannel, type: :channel do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }

  before do
    stub_connection(current_user: user)
  end

  describe "#subscribed" do
    it "tracks the user as a viewer" do
      subscribe(plan_id: plan.id)

      expect(subscription).to be_confirmed
      expect(CoPlan::PlanViewer.where(plan: plan, user: user)).to exist
    end

    it "rejects when plan does not exist" do
      subscribe(plan_id: "nonexistent")
      expect(subscription).to be_rejected
    end

    it "rejects when user is not authorized to view the plan" do
      allow_any_instance_of(CoPlan::PlanPolicy).to receive(:show?).and_return(false)
      subscribe(plan_id: plan.id)
      expect(subscription).to be_rejected
    end
  end

  describe "#unsubscribed" do
    it "expires the viewer record so they disappear immediately" do
      subscribe(plan_id: plan.id)
      expect(CoPlan::PlanViewer.active.where(plan: plan, user: user)).to exist

      subscription.unsubscribe_from_channel

      # Record still exists but is expired (not active)
      expect(CoPlan::PlanViewer.where(plan: plan, user: user)).to exist
      expect(CoPlan::PlanViewer.active.where(plan: plan, user: user)).not_to exist
    end
  end

  describe "#ping" do
    it "updates last_seen_at" do
      subscribe(plan_id: plan.id)
      viewer = CoPlan::PlanViewer.find_by(plan: plan, user: user)
      original_seen_at = viewer.last_seen_at

      travel 1.minute do
        perform :ping
        viewer.reload
        expect(viewer.last_seen_at).to be > original_seen_at
      end
    end
  end
end
