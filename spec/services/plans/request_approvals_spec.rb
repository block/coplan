require "rails_helper"

RSpec.describe CoPlan::Plans::RequestApprovals do
  let(:author) { create(:coplan_user, username: "author") }
  let(:requester) { author }
  let!(:alice) { create(:coplan_user, username: "alice") }
  let!(:bob) { create(:coplan_user, username: "bob") }
  let(:plan) do
    create(:plan, created_by_user: author, touched_files: [
      { "repo" => "squareup/java", "ref" => "main", "path" => "payments/Foo.kt" }
    ])
  end
  let(:router_class) do
    Class.new do
      def source = "test_router"
      def call(**) = @routes
      def routes=(routes)
        @routes = routes
      end
    end
  end
  let(:router) { router_class.new }

  before do
    router.routes = [
      { identity: "alice", metadata: { "repo" => "squareup/java" } },
      { identity: "missing", metadata: { "repo" => "squareup/java" } },
      { identity: "author", metadata: { "repo" => "squareup/java" } }
    ]
    CoPlan.configuration.approval_router = router
  end

  after do
    CoPlan.configuration.approval_router = nil
    CoPlan.configuration.approval_identity_resolver = nil
  end

  it "creates pending approvers and reports identities without local users" do
    result = described_class.call(plan:, requester:)

    expect(result.approvers.map(&:user)).to eq([ alice ])
    expect(result.unresolved_identities).to eq([ "missing" ])
    expect(result.approvers.first).to have_attributes(
      role: "approver", approved_at: nil, routing_source: "test_router",
      routing_metadata: include("identities" => [ "alice" ])
    )
  end

  it "reconciles stale routed approvers but preserves manual approvers" do
    stale = create(:plan_collaborator, :approver, plan:, user: bob, routing_source: "test_router")
    manual_user = create(:coplan_user, username: "manual")
    manual = create(:plan_collaborator, :approver, plan:, user: manual_user)

    described_class.call(plan:, requester:)

    expect { stale.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect(manual.reload).to be_persisted
  end

  it "uses the host identity resolver when configured" do
    CoPlan.configuration.approval_identity_resolver = ->(identity) { identity == "missing" ? bob : CoPlan::User.find_by(username: identity) }

    result = described_class.call(plan:, requester:)

    expect(result.approvers.map(&:user)).to contain_exactly(alice, bob)
    expect(result.unresolved_identities).to be_empty
  end

  it "preserves an approval when an identical route is requested again" do
    collaborator = described_class.call(plan:, requester:).approvers.first
    collaborator.approve!

    rerouted = described_class.call(plan:, requester:).approvers.first

    expect(rerouted.approved_at).to eq(collaborator.approved_at)
  end

  it "emits one approval notification for a new route, not every reconciliation" do
    CoPlan.configuration.notification_handler = ->(*) { }
    expect {
      described_class.call(plan:, requester:)
    }.to have_enqueued_job(CoPlan::NotificationJob).once
    expect {
      described_class.call(plan:, requester:)
    }.not_to have_enqueued_job(CoPlan::NotificationJob)
  ensure
    CoPlan.configuration.notification_handler = nil
  end


  it "wraps adapter failures in a routing error" do
    allow(router).to receive(:call).and_raise("ownership unavailable")

    expect {
      described_class.call(plan:, requester:)
    }.to raise_error(described_class::InvalidRouterResponse, "ownership unavailable")
  end
end
