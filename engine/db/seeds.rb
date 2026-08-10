# Required reference data for a CoPlan installation. Idempotent — safe to run
# repeatedly, and never touches rows the host has customized.
#
# This exists because the SeedGeneralPlanType data migration only runs on
# databases initialized by replaying migrations. Hosts that initialize via
# `db:schema:load` / `db:prepare` / `db:setup` get the tables and the migration
# marked as applied, but not the data — so required reference data must also
# be installable after the fact. Load with `bin/rails coplan:seed` (or
# `CoPlan::Engine.load_seed` from the host's own db/seeds.rb).

# find_by_name is case-insensitive, so a host that renamed the type to
# "general" doesn't get a near-duplicate "General" recreated beside it.
unless CoPlan::PlanType.find_by_name("General")
  CoPlan::PlanType.create!(name: "General", description: "General-purpose plan")
end
