# This migration comes from co_plan (originally 20260717000000)
class ReplaceStatusWithVisibilityAndArchival < ActiveRecord::Migration[8.1]
  # Migration-local model stubs so this migration never breaks as app models
  # evolve. Only the columns touched here are relied upon.
  class MigrationPlan < ActiveRecord::Base
    self.table_name = "coplan_plans"
  end

  class MigrationTag < ActiveRecord::Base
    self.table_name = "coplan_tags"
    before_create { self.id ||= SecureRandom.uuid_v7 }
  end

  class MigrationPlanTag < ActiveRecord::Base
    self.table_name = "coplan_plan_tags"
    before_create { self.id ||= SecureRandom.uuid_v7 }
  end

  def up
    # Plans are shared by default — private drafts are the opt-in exception,
    # so "published" is the column default for new rows.
    add_column :coplan_plans, :visibility, :string, null: false, default: "published"
    add_column :coplan_plans, :archived_at, :datetime
    add_index :coplan_plans, :visibility
    add_index :coplan_plans, :archived_at

    # brainstorm was "private draft"; everything else was org-visible.
    # abandoned was the de-facto archive. developing/live carried lifecycle
    # info some plans genuinely have, so it is preserved as tags rather than
    # destroyed. updated_at is deliberately left untouched — archival state
    # is derived data, not user activity.
    execute <<~SQL
      UPDATE coplan_plans
      SET visibility = CASE WHEN status = 'brainstorm' THEN 'draft' ELSE 'published' END,
          archived_at = CASE WHEN status = 'abandoned' THEN updated_at ELSE NULL END
    SQL

    %w[developing live].each do |lifecycle|
      plan_ids = MigrationPlan.where(status: lifecycle).pluck(:id)
      next if plan_ids.empty?

      tag = MigrationTag.find_or_create_by!(name: lifecycle)
      existing = MigrationPlanTag.where(tag_id: tag.id, plan_id: plan_ids).pluck(:plan_id)
      (plan_ids - existing).each do |plan_id|
        MigrationPlanTag.create!(plan_id: plan_id, tag_id: tag.id)
      end
    end

    remove_index :coplan_plans, :status
    remove_column :coplan_plans, :status
  end

  def down
    add_column :coplan_plans, :status, :string, null: false, default: "brainstorm"
    add_index :coplan_plans, :status

    # Best-effort reversal: draft→brainstorm, archived→abandoned, otherwise
    # considering (the developing/live distinction lives in tags and is not
    # re-derived here).
    execute <<~SQL
      UPDATE coplan_plans
      SET status = CASE
        WHEN visibility = 'draft' THEN 'brainstorm'
        WHEN archived_at IS NOT NULL THEN 'abandoned'
        ELSE 'considering'
      END
    SQL

    remove_index :coplan_plans, :archived_at
    remove_index :coplan_plans, :visibility
    remove_column :coplan_plans, :archived_at
    remove_column :coplan_plans, :visibility
  end
end
