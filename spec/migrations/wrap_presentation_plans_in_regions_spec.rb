require "rails_helper"
require Coplan::Engine.root.join("db/migrate/20260925000000_wrap_presentation_plans_in_regions.rb")

RSpec.describe WrapPresentationPlansInRegions do
  subject(:migration) { described_class.new }

  let(:user) { create(:coplan_user) }
  let(:plan_type) { create(:plan_type, metadata: { described_class::PRESENTATION_MARKER => { "template_content" => "# Legacy" } }) }
  let(:plan) { create(:plan, plan_type: plan_type, created_by_user: user) }

  before { migration.verbose = false }

  it "refuses rollback before schema changes when a migrated presentation was edited" do
    migrated = create(:plan_version, plan: plan, revision: plan.current_revision + 1,
      content_markdown: "::: {.presentation}\n\n# Original\n\n:::", actor_type: "system",
      reason: described_class::MIGRATION_REASON)
    edited = create(:plan_version, plan: plan, revision: migrated.revision + 1,
      content_markdown: "::: {.presentation}\n\n# Edited\n\n:::")
    plan.update_columns(current_plan_version_id: edited.id, current_revision: edited.revision)

    expect(migration).not_to receive(:add_column)
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /incompatible with the legacy renderer/)
  end

  it "refuses rollback when an ordinary plan contains a deck" do
    ordinary_plan = create(:plan, plan_type: create(:plan_type), created_by_user: user)
    version = create(:plan_version, plan: ordinary_plan, revision: ordinary_plan.current_revision + 1,
      content_markdown: "::: {.presentation}\n\n# Embedded deck\n\n:::")
    ordinary_plan.update_columns(current_plan_version_id: version.id, current_revision: version.revision)

    expect(migration).not_to receive(:add_column)
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /incompatible with the legacy renderer/)
  end

  it "allows a plan already restored by an interrupted rollback" do
    migrated = create(:plan_version, plan: plan, revision: plan.current_revision + 1,
      content_markdown: "::: {.presentation}\n\n# Original\n\n:::", actor_type: "system",
      reason: described_class::MIGRATION_REASON)
    restored = create(:plan_version, plan: plan, revision: migrated.revision + 1,
      content_markdown: "# Original", actor_type: "system",
      reason: described_class::ROLLBACK_REASON)
    plan.update_columns(current_plan_version_id: restored.id, current_revision: restored.revision)

    expect { migration.send(:ensure_no_edited_presentations!) }.not_to raise_error
  end
end
