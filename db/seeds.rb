# Engine-required reference data (the General plan type) — idempotent and
# environment-independent. Schema-loaded databases skip the engine's data
# migrations, so this must run everywhere. See engine/db/seeds.rb.
CoPlan::Engine.load_seed

if Rails.env.local?
  require_relative "seeds/development"
  CoPlan::DevelopmentSeed.call
else
  warn "Development seed data is only available in development and test environments."
end
