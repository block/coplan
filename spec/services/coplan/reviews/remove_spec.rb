require "rails_helper"

RSpec.describe CoPlan::Reviews::Remove do
  let(:plan) { create(:plan, :published) }
  let(:reviewer) { create(:coplan_user) }
  let(:task) { CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user) }

  %w[approved changes_requested].each do |decision|
    it "preserves a removed reviewer's #{decision} decisions and starts a new pending request" do
      previous = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1,
        decision: decision, note: decision == "changes_requested" ? "Earlier feedback" : nil)
      other = CoPlan::Reviews::Request.call(plan: plan, reviewer: create(:coplan_user), actor: plan.created_by_user)
      other_response = CoPlan::Reviews::Respond.call(request: other, actor: other.reviewer, revision: 1, decision: "approved")

      described_class.call(plan: plan, request_id: task.id, actor: plan.created_by_user)

      expect(task.reload).to be_removed
      expect(previous.reload.decision).to be_present
      expect(plan.notifications.unread.where(review_request_id: task.id, reason: "review_requested")).to be_empty
      expect(other_response.reload.decision).to eq("approved")
      event = plan.plan_events.find_by!(event_type: "review_removed", after_value: task.id)
      expect(event.actor_id).to eq(plan.created_by_user_id)
      expect(event.metadata).to include("reviewer_name" => reviewer.name)
      expect(task.reload.current_assignment).to be_nil
      expect(plan.review_requests.active).not_to include(task)

      fresh = CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user, create_only: true)
      expect(fresh.id).not_to eq(task.id)
      expect(fresh.status).to eq("pending")
      expect(fresh.review_responses).to be_empty
      expect(fresh.latest_approval).to be_nil
    end
  end

  it "preserves decisions across versions with their original agent attribution" do
    first = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "A revised invitation plan")
    plan.update!(current_plan_version: version, current_revision: 2)
    token = create(:api_token, user: reviewer, agent_name: "Reviewbot")
    second = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 2,
      decision: "changes_requested", note: "Clarify the delivery retry limit", api_token: token)
    snapshots = [ first.attributes, second.attributes ]

    described_class.call(plan: plan, request_id: task.id, actor: plan.created_by_user)

    expect([ first.reload.attributes, second.reload.attributes ]).to eq(snapshots)
    expect(second.comment_thread.comments.first.body_markdown).to eq(second.note)
    expect(plan.review_requests.active).to be_empty
    expect(plan.plan_events.find_by!(event_type: "review_removed").metadata["revision"]).to eq(2)
  end

  it "does not remove or reset the replacement when an old removal is retried" do
    old_id = task.id
    described_class.call(plan: plan, request_id: old_id, actor: plan.created_by_user)
    fresh = CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user, create_only: true)
    approval = CoPlan::Reviews::Respond.call(request: fresh, actor: reviewer, revision: 1, decision: "approved")
    expect { described_class.call(plan: plan, request_id: old_id, actor: plan.created_by_user) }.not_to change(CoPlan::Notification, :count)
    expect(fresh.reload.status).to eq("approved")
    expect(fresh.review_responses).to eq([ approval ])
    expect(plan.plan_events.where(event_type: "review_removed", after_value: old_id).count).to eq(1)
  end

  it "preserves a legacy request's audit before ending the task" do
    legacy = create(:review_request, plan: plan, reviewer: reviewer)
    expect(plan.plan_events.where(event_type: "review_requested")).to be_empty
    described_class.call(plan: plan, request_id: legacy.id, actor: plan.created_by_user)
    event = plan.plan_events.find_by!(event_type: "review_requested", after_value: legacy.id)
    expect(event).to have_attributes(actor_id: legacy.requested_by_user_id, created_at: legacy.requested_at)
    expect(event.metadata).to include("reviewer_name" => reviewer.name, "revision" => 1)
    expect(legacy.reload).to be_removed
  end

  it "announces the old identity's removal when replacing a withdrawn legacy request" do
    legacy = create(:review_request, plan: plan, reviewer: reviewer, status: "withdrawn")
    watcher = create(:api_token, user: reviewer)
    CoPlan::AgentSession.create!(plan: plan, api_token: watcher, state: "watching", agent_name: "Watcher")
    fresh = CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user,
      create_only: true, replace_withdrawn: true)
    payloads = watcher.agent_events.where(event_type: "review.requested").order(:created_at).map(&:payload)
    expect(payloads.size).to eq(2)
    expect(payloads.first).to include("action" => "removed", "removed" => true, "review_request_id" => legacy.id)
    expect(payloads.last).to include("action" => "requested", "review_request_id" => fresh.id)
    expect(plan.plan_events.where(event_type: "review_requested").pluck(:after_value)).to contain_exactly(legacy.id, fresh.id)
    expect(fresh.status).to eq("pending")
  end

  it "keeps the old review if a replacement request is invalid" do
    previous = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    CoPlan::Reviews::Withdraw.call(request: task, actor: plan.created_by_user)
    expect {
      CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user,
        requirement: "invalid", create_only: true, replace_withdrawn: true)
    }.to raise_error(ActiveRecord::RecordInvalid)
    expect(previous.reload.decision).to eq("approved")
    expect(task.reload.status).to eq("withdrawn")
  end

  describe "requests already waiting for the plan lock" do
    self.use_transactional_tests = false
    after { truncate_tables(*(ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata])) }

    %i[respond request_again].each do |action|
      it "rejects an old #{action} after removal and reassignment commit" do
        old_id = task.id
        reviewer_id = reviewer.id
        ready = Queue.new
        worker = nil
        fresh = nil
        plan.with_lock do
          worker = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              stale = CoPlan::ReviewRequest.find(old_id)
              ready << true
              begin
                if action == :respond
                  CoPlan::Reviews::Respond.call(request: stale, actor: stale.reviewer, revision: 1, decision: "approved")
                else
                  CoPlan::Reviews::Request.again(request: stale, actor: stale.requested_by_user)
                end
              rescue ActiveRecord::RecordNotFound => error
                error
              end
            end
          end
          Timeout.timeout(10) { ready.pop }
          described_class.call(plan: plan, request_id: old_id, actor: plan.created_by_user)
          fresh = CoPlan::Reviews::Request.call(plan: plan, reviewer: CoPlan::User.find(reviewer_id),
            actor: plan.created_by_user, create_only: true)
        end
        expect(worker.join(10)).to be_present
        expect(worker.value).to be_a(ActiveRecord::RecordNotFound)
        expect(fresh.reload.status).to eq("pending")
        expect(fresh.review_responses).to be_empty
        expect(plan.review_requests.current.pluck(:id)).to eq([ fresh.id ])
      ensure
        worker&.kill if worker&.alive?
      end
    end
  end
end
