require "rails_helper"

# Covers the engine's required-reference-data seed (engine/db/seeds.rb),
# exposed to hosts as `bin/rails coplan:seed`. Schema-loaded databases skip
# the data migrations, so this seed is the supported way to guarantee the
# built-in plan types and agent harnesses exist. The installers' detailed
# semantics are specced with their models/services; this covers the seed-level
# contract.
RSpec.describe "Coplan::Engine.load_seed" do
  # A migration-built database (the PG CI job) already contains General via
  # the SeedGeneralPlanType data migration; these examples are about the
  # schema-loaded case where types are absent, so start from a clean table.
  # Transactional fixtures roll the delete back after each example.
  before do
    Coplan::PlanType.delete_all
    Coplan::AgentHarness.delete_all
  end

  it "installs the default plan types, General included" do
    expect(Coplan::PlanType.find_by_name("General")).to be_nil

    Coplan::Engine.load_seed

    general = Coplan::PlanType.find_by_name("General")
    expect(general).to be_present
    expect(general.default_tags).to eq([])
    expect(Coplan::PlanType.find_by_name("Engineering Design").template_content).to be_present
  end

  it "is idempotent" do
    Coplan::Engine.load_seed
    expect { Coplan::Engine.load_seed }
      .not_to change { [ Coplan::PlanType.count, Coplan::AgentHarness.count ] }
  end

  it "does not overwrite a host-customized type, while still adding missing ones" do
    customized = create(:plan_type, name: "general", description: "Ours, thanks")

    expect { Coplan::Engine.load_seed }.to change(Coplan::PlanType, :count)
    expect(customized.reload.description).to eq("Ours, thanks")
    expect(Coplan::PlanType.find_by_name("General")).to eq(customized)
  end

  it "installs built-in harnesses without overwriting admin customizations" do
    customized = create(:agent_harness, key: "goose", display_name: "Our Goose")

    Coplan::Engine.load_seed

    expect(Coplan::AgentHarness.pluck(:key)).to include(*Coplan::AgentHarness::BUILT_INS.keys)
    expect(customized.reload.display_name).to eq("Our Goose")
  end
end
