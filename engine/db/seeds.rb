# Required reference data for a CoPlan installation. Idempotent — safe to run
# repeatedly, and never touches rows the host has customized.
#
# This exists because data migrations only run on databases initialized by
# replaying migrations. Hosts that initialize via `db:schema:load` /
# `db:prepare` / `db:setup` get the tables and the migrations marked as
# applied, but not the data — so required reference data must also be
# installable after the fact. Load with `bin/rails coplan:seed` (or
# `CoPlan::Engine.load_seed` from the host's own db/seeds.rb).
#
# Installs the default plan types (engine/db/default_plan_types/*.md):
# creates missing types and fills blank fields on existing ones, never
# overwriting a host's edits. To overwrite with the shipped defaults, run
# `bin/rails coplan:plan_types:install_defaults FORCE=1` explicitly.
CoPlan::PlanTypes::InstallDefaults.call
