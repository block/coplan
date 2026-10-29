require "rails_helper"

RSpec.describe CoPlan::Reviews::Remove do
  let(:plan) { create(:plan, :published) }
  let(:reviewer) { create(:coplan_user) }
  let(:task) { CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user) }

  %w[approved changes_requested].each do |decision|
    it "erases a removed reviewer's #{decision} decisions and starts a new pending request" do
      previous = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1,
        decision: decision, note: decision == "changes_requested" ? "Earlier feedback" : nil)
      other = CoPlan::Reviews::Request.call(plan: plan, reviewer: create(:coplan_user), actor: plan.created_by_user)
      other_response = CoPlan::Reviews::Respond.call(request: other, actor: other.reviewer, revision: 1, decision: "approved")

      described_class.call(plan: plan, request_id: task.id)

      expect(CoPlan::ReviewRequest.exists?(task.id)).to be(false)
      expect(CoPlan::ReviewResponse.exists?(previous.id)).to be(false)
      expect(plan.notifications.where(review_request_id: task.id)).to be_empty
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
