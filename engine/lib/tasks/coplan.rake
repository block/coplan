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

  namespace :demo do
    desc "Install the shared demo library (development/test only; preserves local edits)"
    task seed: :environment do
      require "coplan/development_seed"
      CoPlan::DevelopmentSeed.call
    end
  end
end

# db:prepare also migrates the host's separate queue database.
Rake::Task["db:prepare"].enhance do
  CoPlan::Plan.reset_column_information
  CoPlan::WritingProvenanceBackfillJob.start
end

Rake::Task["db:migrate"].enhance do
  CoPlan::Plan.reset_column_information
  CoPlan::WritingProvenanceBackfillJob.start
end
