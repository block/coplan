# This migration comes from co_plan (originally 20260601000000)
class AddSearchToCoplanPlans < ActiveRecord::Migration[8.1]
  # Adds a denormalized `search_text` column on `coplan_plans` plus an
  # adapter-appropriate index: MySQL gets a FULLTEXT index (used by
  # MATCH … AGAINST), PostgreSQL gets a GIN expression index matching the
  # tsvector expression in `Plan.search`. Other adapters get no index and
  # fall back to LIKE search. See engine/app/models/coplan/plan.rb.
  #
  # The column is maintained by `Plan#refresh_search_text!`, called from
  # after-commit hooks on Plan/PlanTag/PlanVersion.
  def up
    # MySQL text tops out at 64KB and search_text concatenates title, author,
    # tags, and the full stripped content, so it needs MEDIUMTEXT there.
    # PostgreSQL/SQLite text is already effectively unbounded.
    if mysql?
      add_column :coplan_plans, :search_text, :mediumtext
    else
      add_column :coplan_plans, :search_text, :text
    end

    # Backfill before adding the index — index building is faster when the
    # data is already in place, and we want existing plans searchable the
    # moment the app reboots.
    CoPlan::Plan.reset_column_information
    CoPlan::Plan.find_each do |plan|
      plan.update_columns(search_text: CoPlan::Plan.build_search_text(plan))
    end

    if mysql?
      execute "ALTER TABLE coplan_plans ADD FULLTEXT INDEX index_coplan_plans_on_search_text (search_text)"
    elsif postgresql?
      # The expression must match Plan.search's tsvector expression exactly,
      # or the planner won't use the index.
      execute <<~SQL
        CREATE INDEX index_coplan_plans_on_search_text
        ON coplan_plans
        USING GIN ((to_tsvector('simple', coalesce(search_text, ''))))
      SQL
    end
  end

  def down
    if mysql?
      execute "ALTER TABLE coplan_plans DROP INDEX index_coplan_plans_on_search_text"
    elsif postgresql?
      execute "DROP INDEX index_coplan_plans_on_search_text"
    end
    remove_column :coplan_plans, :search_text
  end

  private

  def mysql?
    connection.adapter_name.match?(/mysql/i)
  end

  def postgresql?
    connection.adapter_name.match?(/postg/i)
  end
end
