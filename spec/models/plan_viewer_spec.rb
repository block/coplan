require "rails_helper"

RSpec.describe CoPlan::PlanViewer, type: :model do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }

  describe ".track" do
    it "creates a new viewer record" do
      expect {
        CoPlan::PlanViewer.track(plan: plan, user: user)
      }.to change(CoPlan::PlanViewer, :count).by(1)
    end

    it "updates last_seen_at for existing viewer" do
      CoPlan::PlanViewer.track(plan: plan, user: user)

      travel 1.minute do
        viewer = CoPlan::PlanViewer.track(plan: plan, user: user)
        expect(viewer.last_seen_at).to be_within(1.second).of(Time.current)
      end
    end

    it "does not create duplicate records" do
      CoPlan::PlanViewer.track(plan: plan, user: user)

      expect {
        CoPlan::PlanViewer.track(plan: plan, user: user)
      }.not_to change(CoPlan::PlanViewer, :count)
    end
  end

  describe ".active_viewers_for" do
    it "returns users who are actively viewing" do
      CoPlan::PlanViewer.track(plan: plan, user: user)

      viewers = CoPlan::PlanViewer.active_viewers_for(plan)
      expect(viewers).to eq([user])
    end

    it "excludes stale viewers" do
      CoPlan::PlanViewer.track(plan: plan, user: user)

      travel 3.minutes do
        viewers = CoPlan::PlanViewer.active_viewers_for(plan)
        expect(viewers).to be_empty
      end
    end

    it "returns viewers from different plans independently" do
      other_plan = create(:plan)
      other_user = create(:coplan_user)

      CoPlan::PlanViewer.track(plan: plan, user: user)
      CoPlan::PlanViewer.track(plan: other_plan, user: other_user)

      expect(CoPlan::PlanViewer.active_viewers_for(plan)).to eq([user])
      expect(CoPlan::PlanViewer.active_viewers_for(other_plan)).to eq([other_user])
    end

    it "orders viewers alphabetically by name" do
      zara = create(:coplan_user, name: "Zara")
      alice = create(:coplan_user, name: "Alice")

      CoPlan::PlanViewer.track(plan: plan, user: zara)
      CoPlan::PlanViewer.track(plan: plan, user: alice)

      expect(CoPlan::PlanViewer.active_viewers_for(plan)).to eq([alice, zara])
    end
  end

  describe ".active scope" do
    it "includes recent viewers" do
      viewer = CoPlan::PlanViewer.track(plan: plan, user: user)
      expect(CoPlan::PlanViewer.active).to include(viewer)
    end

    it "excludes stale viewers" do
      viewer = CoPlan::PlanViewer.track(plan: plan, user: user)

      travel 3.minutes do
        expect(CoPlan::PlanViewer.active).not_to include(viewer)
      end
    end
  end
end
