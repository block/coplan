require "rails_helper"

RSpec.describe "Version-bound review evidence" do
  let(:plan) { CoPlan::Plans::Create.call(title: "Reviewed body", content: "# Plan\n\n- [ ] Ship", user: create(:coplan_user)) }
  let(:reviewer) { create(:coplan_user) }
  let(:task) { CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user) }

  def decide(**attributes)
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: plan.reload.current_revision,
      generation: task.reload.generation, decision: "approved", idempotency_key: SecureRandom.uuid, **attributes)
  end

  def replace(content)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content, base_revision: plan.reload.current_revision,
      actor_type: "human", actor_id: plan.created_by_user_id)
  end

  it "pools current-version human decisions while retaining dismissed receipts and withdrawn tasks" do
    first = decide
    other = CoPlan::Reviews::Request.call(plan: plan, reviewer: create(:coplan_user), actor: plan.created_by_user)
    CoPlan::Reviews::Respond.call(request: other, actor: other.reviewer, revision: 1, generation: other.generation, decision: "approved")
    withdrawn = CoPlan::Reviews::Request.call(plan: plan, reviewer: create(:coplan_user), actor: plan.created_by_user)
    CoPlan::Reviews::Withdraw.call(request: withdrawn, actor: plan.created_by_user)
    expect(CoPlan::Reviews::Evidence.call(plan: plan)[:review_requests].count { |r| r[:effective_human_decision] == "approved" }).to eq(2)
    count = CoPlan::Notification.count
    replace("# Plan\n\nRevised")
    expect(CoPlan::Notification.count).to eq(count)
    expect(task.reload).to have_attributes(status: "pending", current_response_id: nil, reset_reason: "content_changed")
    expect(other.reload.status).to eq("pending")
    expect(withdrawn.reload.status).to eq("withdrawn")
    expect(first.reload.plan_version.verified_content!).to eq("# Plan\n\n- [ ] Ship")
    expect(CoPlan::Reviews::Evidence.call(plan: plan)[:review_requests].map { |r| r[:effective_human_decision] }).to all(be_nil)
  end

  it "keeps actual replacement no-ops approved, but never revives A after A to B to A" do
    first = decide
    original = plan.current_content
    sequence = plan.reload.review_sequence
    expect(replace(original.gsub("\n", "\r\n"))[:no_op]).to be(true)
    expect(plan.reload.review_sequence).to eq(sequence)
    expect(task.reload.effective_response).to eq(first)
    replace("B")
    replace(original)
    expect(plan.current_plan_version.content_sha256).to eq(first.plan_version.content_sha256)
    expect(plan.current_plan_version_id).not_to eq(first.plan_version_id)
    expect(task.reload.effective_response).to be_nil
  end

  it "dismisses on human drafts and checkbox edits" do
    decide
    CoPlan::Plans::ToggleCheckbox.call(plan: plan, old_text: "- [ ] Ship", new_text: "- [x] Ship", base_revision: 1, actor_id: plan.created_by_user_id)
    expect(task.reload.effective_response).to be_nil
    decide
    CoPlan::Plans::SaveHumanDraft.call(plan: plan, content: "A human draft", base_revision: 2, actor: plan.created_by_user)
    expect(task.reload).to have_attributes(status: "pending", current_response_id: nil)
  end

  it "dismisses on session commits, including operations that net to the same bytes" do
    first = decide
    session = CoPlan::EditSession.create!(plan: plan, actor_type: "human", actor_id: plan.created_by_user_id,
      base_revision: 1, status: "open", expires_at: 1.hour.from_now,
      draft_content: plan.current_content, operations_json: [ { "op" => "replace_exact", "old_text" => "Ship", "new_text" => "Ship" } ])
    result = CoPlan::Plans::CommitSession.call(session: session)
    expect(result[:version].content_sha256).to eq(first.plan_version.content_sha256)
    expect(task.reload.effective_response).to be_nil
    decide
    empty = CoPlan::EditSession.create!(plan: plan, actor_type: "human", actor_id: plan.created_by_user_id,
      base_revision: 2, status: "open", expires_at: 1.hour.from_now)
    expect(CoPlan::Plans::CommitSession.call(session: empty)[:version]).to be_nil
    expect(task.reload.effective_human_decision).to eq("approved")
  end

  it "rejects delayed first-seen keyed and legacy intentions for a reopened task" do
    task
    old_generation = task.generation
    CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user)
    [ { idempotency_key: SecureRandom.uuid, generation: old_generation }, {} ].each do |attributes|
      expect {
        CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved", **attributes)
      }.to raise_error(CoPlan::Reviews::Respond::Conflict, /request changed/)
    end
    expect(task.reload.effective_response).to be_nil
    expect(decide.request_generation).to eq(task.generation)
  end

  it "orders reconsideration by server sequence, not caller UUID or timestamp, and distinguishes agents" do
    travel_to(Time.current.change(usec: 0)) do
      objection = decide(decision: "changes_requested", note: "Clarify this", idempotency_key: "ffffffff-ffff-4fff-afff-ffffffffffff")
      agent = decide(api_token: create(:api_token, user: reviewer, agent_name: "Reviewbot"), idempotency_key: "00000000-0000-4000-a000-000000000000")
      expect(task.reload.effective_response).to eq(agent)
      expect(task.effective_human_decision).to be_nil
      expect(CoPlan::Reviews::Serialize.call(task)[:latest_human_response_id]).to eq(objection.id)
      human = decide
      expect(task.reload.effective_human_decision).to eq("approved")
      expect(task.review_responses.map(&:id)).to eq([ human.id, agent.id, objection.id ])
      expect([ objection, agent, human ].map(&:decision_sequence)).to eq([ objection.decision_sequence, objection.decision_sequence + 1, objection.decision_sequence + 2 ])
    end
  end

  it "rolls back version, resets and sequence together when a content transaction fails" do
    first = decide
    before = plan.reload.review_sequence
    plan.with_lock do
      replace("Rolled back")
      raise ActiveRecord::Rollback
    end
    expect(plan.reload.current_revision).to eq(1)
    expect(plan.review_sequence).to eq(before)
    expect(task.reload.effective_response).to eq(first)
  end

  it "makes the content boundary explicit and leaves title and attachment metadata outside approval" do
    first = decide
    plan.update!(title: "Different title")
    plan.attachments.attach(io: StringIO.new("mutable resource"), filename: "scope.txt", content_type: "text/plain")
    evidence = CoPlan::Reviews::Evidence.call(plan: plan)
    expect(evidence[:approval_scope][:excludes]).to include("title", "attachments", "embedded_resources", "child_plans")
    expect(evidence[:version][:content_markdown]).to eq(first.plan_version.content_markdown)
    expect(task.reload.effective_response).to eq(first)
  end
end
