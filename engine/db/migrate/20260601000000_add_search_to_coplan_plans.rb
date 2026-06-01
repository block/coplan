class AddSearchToCoplanPlans < ActiveRecord::Migration[8.1]
  # Adds a denormalized `search_text` column on `coplan_plans` plus a MySQL
  # FULLTEXT index. This is the one explicit MySQL-ism in the engine; see
  # AGENTS.md ("Tech Stack & Philosophy"). The schema otherwise stays portable.
  #
  # The column is maintained by `Plan#refresh_search_text!`, called from
  # after-commit hooks on Plan/PlanTag/PlanVersion. See engine/app/models/coplan/plan.rb.
  def up
    add_column :coplan_plans, :search_text, :mediumtext

    # Backfill before adding the FULLTEXT index — FULLTEXT building is faster
    # when the data is already in place, and we want existing plans searchable
    # the moment the app reboots.
    CoPlan::Plan.reset_column_information
    CoPlan::Plan
      .includes(:created_by_user, :tags, :current_plan_version)
      .find_each do |plan|
        plan.update_columns(search_text: CoPlan::Plan.build_search_text(plan))
      end

    if mysql?
      execute "ALTER TABLE coplan_plans ADD FULLTEXT INDEX index_coplan_plans_on_search_text (search_text)"
    end
  end

  def down
    if mysql?
      execute "ALTER TABLE coplan_plans DROP INDEX index_coplan_plans_on_search_text"
    end
    remove_column :coplan_plans, :search_text
  end

  private

  def mysql?
    connection.adapter_name.match?(/mysql/i)
  end
end
