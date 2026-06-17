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

    it "authenticates through the engine callback when the connection has no current_user" do
      stub_connection(request: ActionDispatch::Request.empty)
      allow(CoPlan.configuration).to receive(:authenticate).and_return(
        ->(_request) { { external_id: "websocket-user", name: "Websocket User" } }
      )
      plan = create(:plan, created_by_user: user)

      subscribe(plan_id: plan.id)

      websocket_user = CoPlan::User.find_by!(external_id: "websocket-user")
      expect(subscription).to be_confirmed
      expect(CoPlan::PlanViewer.where(plan: plan, user: websocket_user)).to exist
    end

    it "authenticates through the engine callback when ActionCable keeps the request private" do
      request = ActionDispatch::Request.empty
      private_request_connection = Class.new do
        def initialize(request)
          @request = request
        end

        private

        attr_reader :request
      end.new(request)
      channel = described_class.allocate
      allow(channel).to receive(:connection).and_return(private_request_connection)
      allow(CoPlan.configuration).to receive(:authenticate).and_return(
        ->(received_request) { { external_id: "private-request-user", name: received_request.object_id.to_s } }
      )

      websocket_user = channel.send(:resolve_current_user)

      expect(websocket_user.external_id).to eq("private-request-user")
      expect(websocket_user.name).to eq(request.object_id.to_s)
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
