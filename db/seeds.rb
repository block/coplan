# Engine-required reference data (plan types and known agent harnesses) —
# idempotent and environment-independent. Schema-loaded databases skip the
# engine's data migrations, so this must run everywhere. See engine/db/seeds.rb.
Coplan::Engine.load_seed

if Rails.env.local?
  require "coplan/development_seed"
  Coplan::DevelopmentSeed.call
else
  warn "Development seed data is only available in development and test environments."
end
