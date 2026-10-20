# This migration comes from co_plan (originally 20261019000000)
class ScheduleWritingProvenanceBackfill < ActiveRecord::Migration[8.1]
  def up
    add_column :coplan_plans, :writing_provenance_backfill, :json
    schedule_existing_plans
    # Workers discover durable requests after deployment. A fresh host's
    # separate queue database may not have been migrated yet.
  end

  def schedule_existing_plans
    plans = Class.new(ActiveRecord::Base) { self.table_name = "coplan_plans" }
    plans.reset_column_information
    plans.where(writing_provenance_backfill: nil).select(:id, :current_revision).find_each do |plan|
      plan.update_columns(writing_provenance_backfill: { "legacy_revision" => plan.current_revision, "revision" => 0 })
    end
  end

  def down
    remove_column :coplan_plans, :writing_provenance_backfill
  end
end
