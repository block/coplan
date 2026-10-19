require "rails_helper"

RSpec.describe CoPlan::Plans::WritingProvenanceBackfill do
  let(:user) { create(:coplan_user) }
  let(:plan) { CoPlan::Plans::Create.call(title: "Legacy", content: "Old editor", user: user, actor_type: "human") }

  def rollout(plan, revision: plan.current_revision)
    plan.update_columns(writing_provenance_backfill: { "legacy_revision" => revision, "revision" => 0 })
    plan
  end

  def run_batch(plan, token = described_class.claim(plan))
    described_class.call(plan: plan, token: token)
  end

  it "assumes legacy editor additions are human and preserves later pasted input" do
    rollout(plan)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Old editor paste", base_revision: 1, actor_type: "human", actor_id: user.id,
      input_sources: { "runs" => [ [ 10, "unknown" ], [ 6, "unknown" ] ] })
    run_batch(plan)
    expect(plan.reload.writing_provenance_summary.fetch("counts")).to eq("human" => 9, "ai" => 0, "unknown" => 5)
    expect(plan.writing_provenance_backfill).to eq("legacy_revision" => 1, "revision" => 2)
  end

  it "keeps retained agent writing when a historical human adds text" do
    agent = CoPlan::Plans::Create.call(title: "Mixed history", content: "Agent", user: user, actor_type: "local_agent")
    CoPlan::Plans::ReplaceContent.call(plan: agent, new_content: "Agent human", base_revision: 1, actor_type: "human", actor_id: user.id)
    rollout(agent)
    run_batch(agent)
    expect(agent.reload.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 5, "unknown" => 0)
  end

  it "uses a database claim across instances and rejects an expired worker's checkpoint" do
    rollout(plan)
    original = described_class.claim(plan)
    expect(described_class.claim(CoPlan::Plan.find(plan.id))).to be_nil
    travel described_class::LEASE + 1.second
    replacement = described_class.claim(CoPlan::Plan.find(plan.id))
    expect(replacement).not_to eq(original)
    expect(run_batch(plan, original)).to be(false)
    expect(plan.reload.writing_provenance_backfill.fetch("revision")).to eq(0)
    run_batch(plan, replacement)
    expect(plan.reload.writing_provenance_summary.dig("shares", "human")).to eq(1.0)
  end

  it "resumes at the committed checkpoint after a failed version without replaying earlier versions" do
    rollout(plan)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Old editor new", base_revision: 1, actor_type: "human", actor_id: user.id)
    token = described_class.claim(plan)
    allow(CoPlan::Plans::WritingProvenance).to receive(:call).and_wrap_original do |method, **args|
      raise "worker interrupted" if args.fetch(:version).revision == 2
      method.call(**args)
    end
    expect { run_batch(plan, token) }.to raise_error("worker interrupted")
    expect(plan.reload.writing_provenance_backfill.fetch("revision")).to eq(1)
    allow(CoPlan::Plans::WritingProvenance).to receive(:call).and_call_original
    expect(CoPlan::Plans::WritingProvenance).not_to receive(:call).with(version: have_attributes(revision: 1), previous: anything, historical_human: anything)
    run_batch(plan, token)
    expect(plan.reload.writing_provenance_backfill.fetch("revision")).to eq(2)
  end

  it "yields after a bounded batch and advances the checkpoint on later normal saves" do
    rollout(plan)
    stub_const("#{described_class}::BATCH_SIZE", 1)
    token = described_class.claim(plan)
    expect(run_batch(plan, token)).to be(true)
    expect(run_batch(plan, token)).to be(false)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Old editor typed", base_revision: 1, actor_type: "human", actor_id: user.id,
      input_sources: { "runs" => [ [ 16, "human" ] ] })
    expect(plan.reload.writing_provenance_backfill).to eq("legacy_revision" => 1, "revision" => 2)
    expect(described_class.pending?(plan)).to be(false)
  end

  it "applies the historical assumption to large editor rewrites without unbounded diffing" do
    legacy = CoPlan::Plans::Create.call(title: "Large legacy", content: "a" * 2000, user: user, actor_type: "human")
    CoPlan::Plans::ReplaceContent.call(plan: legacy, new_content: "b" * 2000, base_revision: 1, actor_type: "human", actor_id: user.id)
    rollout(legacy)
    run_batch(legacy)
    expect(legacy.reload.writing_provenance_summary.dig("shares", "human")).to eq(1.0)
  end

  it "does not let a worker that loses its claim during computation write a checkpoint" do
    rollout(plan)
    token = described_class.claim(plan)
    allow(CoPlan::Plans::WritingProvenance).to receive(:call).and_wrap_original do |method, **args|
      snapshot = method.call(**args)
      travel described_class::LEASE + 1.second
      described_class.claim(CoPlan::Plan.find(plan.id))
      snapshot
    end
    expect(run_batch(plan, token)).to be(false)
    expect(plan.reload.writing_provenance_backfill.fetch("revision")).to eq(0)
  end
end
