require "rails_helper"

RSpec.describe CoPlan::Reviews::Remove do
  let(:plan) { create(:plan, :published) }
  let(:reviewer) { create(:coplan_user) }
  let(:task) { CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user) }

  %w[approved changes_requested].each do |decision|
    it "erases a removed reviewer's #{decision} decisions and starts a new pending request" do
      watcher = create(:api_token, user: plan.created_by_user)
      CoPlan::AgentSession.create!(plan: plan, api_token: watcher, state: "watching", agent_name: "Authorbot")
      previous = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1,
        decision: decision, note: decision == "changes_requested" ? "Earlier feedback" : nil)
      other = CoPlan::Reviews::Request.call(plan: plan, reviewer: create(:coplan_user), actor: plan.created_by_user)
      other_response = CoPlan::Reviews::Respond.call(request: other, actor: other.reviewer, revision: 1, decision: "approved")

      described_class.call(plan: plan, request_id: task.id)

      expect(CoPlan::ReviewRequest.exists?(task.id)).to be(false)
      expect(CoPlan::ReviewResponse.exists?(previous.id)).to be(false)
      expect(plan.notifications.where(review_request_id: task.id)).to be_empty
      expect(plan.plan_events.where(after_value: task.id)).to be_empty
      expect(watcher.agent_events.where(event_type: "review.responded").map { |event| event.payload["review_request_id"] }).to eq([ other.id ])
      expect(watcher.agent_events.last.payload).to include("action" => "removed", "review_request_id" => task.id)
      expect(other_response.reload.decision).to eq("approved")

      fresh = CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user, create_only: true)
      expect(fresh.id).not_to eq(task.id)
      expect(fresh.status).to eq("pending")
      expect(fresh.review_responses).to be_empty
      expect(fresh.latest_approval).to be_nil
    end
  end

  it "does not remove or reset the replacement when an old removal is retried" do
    old_id = task.id
    described_class.call(plan: plan, request_id: old_id)
    fresh = CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user, create_only: true)
    approval = CoPlan::Reviews::Respond.call(request: fresh, actor: reviewer, revision: 1, decision: "approved")
    expect { described_class.call(plan: plan, request_id: old_id) }.not_to change(CoPlan::Notification, :count)
    expect(fresh.reload.status).to eq("approved")
    expect(fresh.review_responses).to eq([ approval ])
  end

  it "rejects an old re-request already in flight when the request is removed" do
    old_id = task.id
    described_class.call(plan: plan, request_id: old_id)
    expect {
      CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user, request_id: old_id)
    }.to raise_error(ActiveRecord::RecordNotFound)
    expect(plan.review_requests).to be_empty
  end

  it "does not erase a request from another plan" do
    task
    expect(described_class.call(plan: create(:plan, :published), request_id: task.id)).to be_nil
    expect(task.reload.status).to eq("pending")
  end

  it "does not republish an erased response when its post-commit fan-out runs late" do
    watcher = create(:api_token, user: plan.created_by_user)
    CoPlan::AgentSession.create!(plan: plan, api_token: watcher, state: "watching", agent_name: "Authorbot")
    stale_request = task
    described_class.call(plan: plan, request_id: task.id)
    CoPlan::Reviews::Changed.call(request: stale_request, event_type: "review.responded", payload: { "decision" => "approved" })
    expect(watcher.agent_events.where(event_type: "review.responded")).to be_empty
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
                  CoPlan::Reviews::Request.call(plan: stale.plan, reviewer: stale.reviewer,
                    actor: stale.requested_by_user, request_id: old_id)
                end
              rescue ActiveRecord::RecordNotFound => error
                error
              end
            end
          end
          Timeout.timeout(10) { ready.pop }
          described_class.call(plan: plan, request_id: old_id)
          fresh = CoPlan::Reviews::Request.call(plan: plan, reviewer: CoPlan::User.find(reviewer_id),
            actor: plan.created_by_user, create_only: true)
        end
        expect(worker.join(10)).to be_present
        expect(worker.value).to be_a(ActiveRecord::RecordNotFound)
        expect(fresh.reload.status).to eq("pending")
        expect(fresh.review_responses).to be_empty
        expect(plan.review_requests.pluck(:id)).to eq([ fresh.id ])
      ensure
        worker&.kill if worker&.alive?
      end
    end
  end
end
