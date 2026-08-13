require "rails_helper"

# Covers the engine's required-reference-data seed (engine/db/seeds.rb),
# exposed to hosts as `bin/rails coplan:seed`. Schema-loaded databases skip
# the SeedGeneralPlanType data migration, so this seed is the supported way
# to guarantee the built-in General plan type exists.
RSpec.describe "CoPlan::Engine.load_seed" do
  # A migration-built database (the PG CI job) already contains General via
  # the SeedGeneralPlanType data migration; these examples are about the
  # schema-loaded case where it's absent, so start from a clean table.
  # Transactional fixtures roll the delete back after each example.
  before { CoPlan::PlanType.delete_all }

  it "creates the General plan type when missing" do
    expect(CoPlan::PlanType.find_by_name("General")).to be_nil

    CoPlan::Engine.load_seed

    general = CoPlan::PlanType.find_by_name("General")
    expect(general).to be_present
    expect(general.description).to eq("General-purpose plan")
    expect(general.default_tags).to eq([])
    expect(general.metadata).to eq({})
  end

  it "is idempotent" do
    CoPlan::Engine.load_seed
    expect { CoPlan::Engine.load_seed }.not_to change(CoPlan::PlanType, :count)
  end

  it "does not overwrite a host-customized General plan type" do
    customized = create(:plan_type, name: "general", description: "Ours, thanks")

    expect { CoPlan::Engine.load_seed }.not_to change(CoPlan::PlanType, :count)
    expect(customized.reload.description).to eq("Ours, thanks")
  end
end
