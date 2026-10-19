require "rails_helper"

RSpec.describe CoPlan::WritingProvenanceJob do
  it "coalesces requests durably and releases a claim if the queue is unavailable" do
    plan = CoPlan::Plans::Create.call(title: "Queue outage", content: "Old", user: create(:coplan_user), actor_type: "human")
    allow(described_class).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, "offline")
    expect { described_class.request(plan) }.not_to raise_error
    expect(plan.reload.writing_provenance_backfill["token"]).to be_nil
    allow(described_class).to receive(:perform_later).and_call_original
    expect(described_class.request(plan)).to be(true)
    expect(described_class.request(CoPlan::Plan.find(plan.id))).to be(false)
  end
  it "reconstructs legacy agents, preserves new human evidence, and is idempotent" do
    user = create(:coplan_user)
    plan = CoPlan::Plans::Create.call(title: "Backfill", content: "Agent", user: user, actor_type: "local_agent")
    plan.current_plan_version.update_columns(writing_provenance: nil)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Agent typed", base_revision: 1, actor_type: "human", actor_id: user.id,
      input_sources: { "runs" => [ [ 5, "unknown" ], [ 6, "human" ] ] })
    expect(plan.writing_provenance_summary.dig("counts", "unknown")).to eq(5)
    described_class.perform_now(plan_id: plan.id, restart: true)
    expect(plan.reload.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 5, "unknown" => 0)
    snapshot = plan.current_plan_version.reload.writing_provenance.deep_dup
    described_class.perform_now(plan_id: plan.id)
    expect(plan.current_plan_version.reload.writing_provenance).to eq(snapshot)
  end

  it "uses the recorded fixture identity when upgrading an older human-saved demo" do
    user = create(:coplan_user)
    plan = CoPlan::Plans::Create.call(title: "Old demo", content: "Generated demo", user: user, actor_type: "human")
    version = plan.current_plan_version
    snapshot = version.writing_provenance.merge("write_source" => { "kind" => "ai", "agent_name" => "Demo agent" })
    version.update_columns(writing_provenance: snapshot)
    described_class.perform_now(plan_id: plan.id)
    expect(plan.reload.writing_provenance_summary.dig("counts", "ai")).to eq(13)
    expect(plan.writing_provenance_summary.dig("counts", "unknown")).to eq(0)
  end
end
