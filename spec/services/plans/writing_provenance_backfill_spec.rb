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

  it "repairs completed pre-identity history without changing content or actor records" do
    old = plan.current_plan_version
    old.update_columns(created_at: Time.utc(2026, 7, 9), writing_provenance: old.writing_provenance.except("history_policy"))
    rollout(plan)
    old.input_sources = { "runs" => [ [ old.content_markdown.length, "human" ] ] }
    old_snapshot = CoPlan::Plans::WritingProvenance.call(version: old, historical_human: true)
    old.update_columns(writing_provenance: old_snapshot.except("history_policy"))
    plan.update_columns(writing_provenance_summary: old_snapshot.fetch("summary"),
      writing_provenance_backfill: { "legacy_revision" => 1, "revision" => 1, "finalized_revision" => 1 })
    expect(plan.writing_provenance_summary.dig("shares", "human")).to eq(1.0)
    expect(described_class.pending?(plan)).to be(true)

    run_batch(plan)

    expect(plan.reload.writing_provenance_summary.dig("shares", "unknown")).to eq(1.0)
    expect(plan.plan_versions.count).to eq(1)
    expect(old.reload).to have_attributes(actor_type: "human", content_markdown: "Old editor")
    expect(old.writing_provenance["historical_human"]).to be_nil
    expect(described_class.pending?(plan)).to be(false)
    expect(described_class.claim(plan)).to be_nil
    run_batch(plan, described_class.claim(plan, restart: true))
    expect(plan.reload.writing_provenance_summary.dig("shares", "unknown")).to eq(1.0)
  end

  it "keeps the early unknown text when later historical editor input is human" do
    plan.current_plan_version.update_columns(created_at: Time.utc(2026, 7, 9))
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Old editor typed", base_revision: 1, actor_type: "human", actor_id: user.id)
    plan.current_plan_version.update_columns(created_at: Time.utc(2026, 8, 18))
    rollout(plan)
    run_batch(plan)
    expect(plan.reload.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 0, "unknown" => 9)
  end

  it "uses surviving revoked token evidence ahead of an incorrect human snapshot" do
    token, = CoPlan::ApiToken.create_with_raw_token(user: user, name: "Claude", agent_name: "Claude",
      revoked_at: Time.current, metadata: { "harness" => "claude-code", "model" => "recorded-model" })
    version = plan.current_plan_version
    version.update_columns(created_at: Time.utc(2026, 7, 9), api_token_id: token.id,
      writing_provenance: version.writing_provenance.merge("write_source" => { "kind" => "human", "user_id" => user.id }))
    rollout(plan)
    run_batch(plan)
    expect(plan.reload.writing_provenance_summary.dig("shares", "ai")).to eq(1.0)
    expect(plan.writing_provenance_summary.fetch("contributors").first).to include("agent_name" => "Claude", "model" => "recorded-model")
  end

  it "preserves explicit agent snapshots and legacy agent names before the boundary" do
    version = plan.current_plan_version
    version.update_columns(created_at: Time.utc(2026, 7, 9), agent_name: "Claude")
    rollout(plan)
    run_batch(plan)
    expect(plan.reload.writing_provenance_summary.dig("shares", "ai")).to eq(1.0)
    version.update_columns(agent_name: nil)
    run_batch(plan, described_class.claim(plan, restart: true))
    expect(plan.reload.writing_provenance_summary.dig("shares", "ai")).to eq(1.0)
  end

  it "restarts an old worker's checkpoint before publishing a repaired summary" do
    plan.current_plan_version.update_columns(created_at: Time.utc(2026, 7, 9))
    rollout(plan)
    token = described_class.claim(plan)
    plan.update_columns(writing_provenance_backfill: plan.writing_provenance_backfill.merge("revision" => 1))
    version = plan.current_plan_version
    version.update_columns(writing_provenance: version.writing_provenance.except("history_policy"))
    run_batch(plan, token)
    expect(plan.reload.writing_provenance_summary.dig("shares", "unknown")).to eq(1.0)
    expect(described_class.pending?(plan)).to be(false)
  end

  it "repairs old retained text even when a new editor save advanced the completed checkpoint" do
    old = plan.current_plan_version
    old.input_sources = { "runs" => [ [ old.content_markdown.length, "human" ] ] }
    old.update_columns(created_at: Time.utc(2026, 7, 9))
    snapshot = CoPlan::Plans::WritingProvenance.call(version: old, historical_human: true).except("history_policy")
    old.update_columns(writing_provenance: snapshot)
    plan.update_columns(writing_provenance_summary: snapshot.fetch("summary"),
      writing_provenance_backfill: { "legacy_revision" => 1, "revision" => 1, "finalized_revision" => 1 })
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Old editor typed", base_revision: 1, actor_type: "human", actor_id: user.id,
      input_sources: { "runs" => [ [ 16, "human" ] ] })
    expect(plan.reload.writing_provenance_backfill.fetch("revision")).to eq(2)
    expect(plan.current_plan_version.writing_provenance["history_policy"]).to be_nil
    run_batch(plan)
    expect(plan.reload.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 0, "unknown" => 9)
  end

  it "assumes legacy editor additions are human and preserves later pasted input" do
    rollout(plan)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Old editor paste", base_revision: 1, actor_type: "human", actor_id: user.id,
      input_sources: { "runs" => [ [ 10, "unknown" ], [ 6, "unknown" ] ] })
    run_batch(plan)
    expect(plan.reload.writing_provenance_summary.fetch("counts")).to eq("human" => 9, "ai" => 0, "unknown" => 5)
    expect(plan.writing_provenance_backfill).to eq("legacy_revision" => 1, "revision" => 2, "finalized_revision" => 2, "policy_version" => 2)
  end

  it "keeps retained agent writing when a historical human adds text" do
    agent = CoPlan::Plans::Create.call(title: "Mixed history", content: "Agent", user: user, actor_type: "local_agent")
    CoPlan::Plans::ReplaceContent.call(plan: agent, new_content: "Agent human", base_revision: 1, actor_type: "human", actor_id: user.id)
    rollout(agent)
    run_batch(agent)
    expect(agent.reload.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 5, "unknown" => 0)
  end

  it "includes old writers after the cutoff without treating interleaved instrumented paste as human" do
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Old editor oldworker", base_revision: 1, actor_type: "human", actor_id: user.id)
    pasted = "Old editor oldworker paste"
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: pasted, base_revision: 2, actor_type: "human", actor_id: user.id,
      input_sources: { "runs" => [ [ pasted.length, "unknown" ] ] })
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "#{pasted} moreold", base_revision: 3, actor_type: "human", actor_id: user.id)
    plan.plan_versions.where(revision: [ 2, 4 ]).update_all(writing_provenance: nil)
    rollout(plan, revision: 1)
    run_batch(plan)
    expect(plan.reload.writing_provenance_summary.fetch("counts")).to eq("human" => 25, "ai" => 0, "unknown" => 5)
    expect(plan.plan_versions.find_by!(revision: 2).writing_provenance["historical_human"]).to be(true)
    expect(plan.plan_versions.find_by!(revision: 3).writing_provenance["historical_human"]).to be_nil
  end

  it "rebuilds new plans from old writers without a cutoff and preserves that assumption on replay" do
    late = CoPlan::Plans::Create.call(title: "During deployment", content: "a" * 2000, user: user, actor_type: "human")
    CoPlan::Plans::ReplaceContent.call(plan: late, new_content: "b" * 2000, base_revision: 1, actor_type: "human", actor_id: user.id)
    late.plan_versions.update_all(writing_provenance: nil)
    late.update_columns(writing_provenance_summary: nil)
    run_batch(late)
    expect(late.reload.writing_provenance_summary.dig("shares", "human")).to eq(1.0)
    expect(late.writing_provenance_backfill.fetch("legacy_revision")).to eq(0)
    run_batch(late, described_class.claim(late, restart: true))
    expect(late.reload.writing_provenance_summary.dig("shares", "human")).to eq(1.0)
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
    expect(plan.reload.writing_provenance_backfill).to eq("legacy_revision" => 1, "revision" => 2, "finalized_revision" => 2, "policy_version" => 2)
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

  it "recovers a worker lost after the last checkpoint even when the old summary has the current revision" do
    rollout(plan)
    stub_const("#{described_class}::BATCH_SIZE", 1)
    token = described_class.claim(plan)
    expect(run_batch(plan, token)).to be(true)
    expect(plan.reload.writing_provenance_summary.dig("shares", "unknown")).to eq(1.0)
    expect(described_class.pending?(plan)).to be(true)
    travel described_class::LEASE + 1.second
    replacement = described_class.claim(CoPlan::Plan.find(plan.id))
    expect(replacement).to be_present
    expect(run_batch(plan, replacement)).to be(false)
    expect(plan.reload.writing_provenance_summary.dig("shares", "human")).to eq(1.0)
    expect(described_class.pending?(plan)).to be(false)
  end

  it "keeps finalization pending when an enqueue failure releases the final checkpoint claim" do
    rollout(plan)
    stub_const("#{described_class}::BATCH_SIZE", 1)
    token = described_class.claim(plan)
    run_batch(plan, token)
    described_class.release(plan, token)
    expect(described_class.pending?(plan.reload)).to be(true)
    replacement = described_class.claim(plan)
    expect(replacement).to be_present
    run_batch(plan, replacement)
    expect(described_class.pending?(plan.reload)).to be(false)
  end
end
