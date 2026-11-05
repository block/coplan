require "rails_helper"

RSpec.describe CoPlan::WritingProvenanceBackfillJob do
  it "starts independently of the cache and tolerates an unavailable queue database" do
    expect(Rails).not_to receive(:cache)
    allow(described_class).to receive(:perform_later).and_raise(StandardError, "queue unavailable")
    expect { described_class.start }.not_to raise_error
    allow(described_class).to receive(:perform_later).and_call_original
    expect { described_class.start }.to have_enqueued_job(described_class).exactly(:once)
  end
  it "automatically requests existing histories and schedules crash recovery" do
    plan = CoPlan::Plans::Create.call(title: "Old", content: "Editor", user: create(:coplan_user), actor_type: "human")
    plan.update_columns(writing_provenance_backfill: { "legacy_revision" => 1, "revision" => 0 })
    expect(CoPlan::WritingProvenanceJob).to receive(:request).with(have_attributes(id: plan.id))
    expect { described_class.perform_now }.to have_enqueued_job(described_class).at(a_value_within(2.seconds).of((CoPlan::Plans::WritingProvenanceBackfill::LEASE + 30.seconds).from_now))
  end

  it "does not rebuild completed documents" do
    plan = CoPlan::Plans::Create.call(title: "Ready", content: "Editor", user: create(:coplan_user), actor_type: "human")
    plan.update_columns(writing_provenance_backfill: { "legacy_revision" => 1, "revision" => 1, "finalized_revision" => 1, "policy_version" => CoPlan::Plans::WritingProvenance::HISTORY_POLICY })
    expect(CoPlan::WritingProvenanceJob).not_to receive(:request)
    expect { described_class.perform_now }.not_to have_enqueued_job(described_class)
  end

  it "automatically revisits summaries completed under the old attribution policy" do
    plan = CoPlan::Plans::Create.call(title: "Previously rebuilt", content: "Old API input", user: create(:coplan_user), actor_type: "human")
    plan.update_columns(writing_provenance_backfill: { "legacy_revision" => 1, "revision" => 1, "finalized_revision" => 1 })
    expect(CoPlan::WritingProvenanceJob).to receive(:request).with(have_attributes(id: plan.id))
    described_class.perform_now
  end

  it "revisits cached summaries without a backfill checkpoint" do
    plan = CoPlan::Plans::Create.call(title: "Created after rollout", content: "Known writing", user: create(:coplan_user), actor_type: "human")
    expect(plan.writing_provenance_summary).to be_present
    expect(plan.writing_provenance_backfill).to be_nil
    expect(CoPlan::WritingProvenanceJob).to receive(:request).with(have_attributes(id: plan.id))
    described_class.perform_now
  end

  it "discovers plans created by old instances after the migration scan" do
    plan = CoPlan::Plans::Create.call(title: "During cutover", content: "Editor", user: create(:coplan_user), actor_type: "human")
    plan.plan_versions.update_all(writing_provenance: nil)
    plan.update_columns(writing_provenance_summary: nil)
    expect(CoPlan::WritingProvenanceJob).to receive(:request).with(have_attributes(id: plan.id))
    described_class.perform_now
  end

  it "does not keep versionless documents in the recovery scan" do
    plan = CoPlan::Plan.create!(title: "No version yet", created_by_user: create(:coplan_user))
    plan.update_columns(writing_provenance_backfill: { "legacy_revision" => 0, "revision" => 0 })
    expect(CoPlan::WritingProvenanceJob).not_to receive(:request)
    expect { described_class.perform_now }.not_to have_enqueued_job(described_class)
  end
end
