require "rails_helper"
require CoPlan::Engine.root.join("db/migrate/20261019000000_schedule_writing_provenance_backfill.rb")

RSpec.describe ScheduleWritingProvenanceBackfill do
  it "captures existing revisions once without reading or replaying document history" do
    plan = CoPlan::Plans::Create.call(title: "Before rollout", content: "Editor", user: create(:coplan_user), actor_type: "human")
    expect(CoPlan::Plans::WritingProvenance).not_to receive(:call)
    described_class.new.schedule_existing_plans
    expect(plan.reload.writing_provenance_backfill).to eq("legacy_revision" => 1, "revision" => 0)
    plan.update_columns(current_revision: 2)
    described_class.new.schedule_existing_plans
    expect(plan.reload.writing_provenance_backfill.fetch("legacy_revision")).to eq(1)
  end
end
