# Engine migrations are copied into the host app manually when bumping
# the coplan-engine gem version, via:
#
#   bin/rails co_plan:install:migrations
#   bin/rails db:migrate
#
# We intentionally do NOT enhance db:migrate with install:migrations
# because deployed containers have a read-only filesystem.

namespace :coplan do
  desc "Install CoPlan's required reference data (idempotent; see engine/db/seeds.rb)"
  task seed: :environment do
    CoPlan::Engine.load_seed
  end
end
