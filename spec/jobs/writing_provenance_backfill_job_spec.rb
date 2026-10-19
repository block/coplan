require "rails_helper"

RSpec.describe CoPlan::WritingProvenanceBackfillJob do
  it "coalesces startup scans and tolerates an unavailable queue database" do
    cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(cache)
    allow(described_class).to receive(:perform_later).and_raise(StandardError, "queue unavailable")
    expect { described_class.start }.not_to raise_error
    allow(described_class).to receive(:perform_later).and_call_original
    expect { 2.times { described_class.start } }.to have_enqueued_job(described_class).exactly(:once)
  end
  it "automatically requests existing histories and schedules crash recovery" do
    plan = CoPlan::Plans::Create.call(title: "Old", content: "Editor", user: create(:coplan_user), actor_type: "human")
    plan.update_columns(writing_provenance_backfill: { "legacy_revision" => 1, "revision" => 0 })
    expect(CoPlan::WritingProvenanceJob).to receive(:request).with(have_attributes(id: plan.id))
    expect { described_class.perform_now }.to have_enqueued_job(described_class).at(a_value_within(2.seconds).of((CoPlan::Plans::WritingProvenanceBackfill::LEASE + 30.seconds).from_now))
  end

  it "does not rebuild completed documents" do
    plan = CoPlan::Plans::Create.call(title: "Ready", content: "Editor", user: create(:coplan_user), actor_type: "human")
    plan.update_columns(writing_provenance_backfill: { "legacy_revision" => 1, "revision" => 1 })
    expect(CoPlan::WritingProvenanceJob).not_to receive(:request)
    expect { described_class.perform_now }.not_to have_enqueued_job(described_class)
  end
end
