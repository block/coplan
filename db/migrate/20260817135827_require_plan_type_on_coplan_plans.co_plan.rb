# This migration comes from co_plan (originally 20260817000000)
class RequirePlanTypeOnCoplanPlans < ActiveRecord::Migration[8.1]
  # Untyped plans are no longer representable: backfill any strays onto the
  # General catch-all (created by SeedGeneralPlanType, but recreated here in
  # case a host deleted it while deletion still nullified plans), then
  # enforce NOT NULL. Raw portable SQL, same reasoning as SeedGeneralPlanType:
  # this must run identically on MySQL and PostgreSQL hosts.
  def up
    # select_value, not execute: raw execute result rows are arrays on
    # mysql2 but hashes on pg, so indexing into them isn't portable.
    general_id = connection.select_value("SELECT id FROM coplan_plan_types WHERE LOWER(name) = 'general' LIMIT 1")

    unless general_id
      general_id = SecureRandom.uuid_v7
      execute <<~SQL
        INSERT INTO coplan_plan_types (id, name, description, default_tags, template_content, metadata, created_at, updated_at)
        VALUES (#{quote(general_id)}, 'General', 'General-purpose plan', '[]', NULL, '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    execute <<~SQL
      UPDATE coplan_plans SET plan_type_id = #{quote(general_id)} WHERE plan_type_id IS NULL
    SQL

    # MySQL can't MODIFY a column that participates in a foreign key —
    # drop the FK around the null change and put it back (a no-op dance on
    # PostgreSQL, but portable).
    had_fk = foreign_key_exists?(:coplan_plans, column: :plan_type_id)
    remove_foreign_key :coplan_plans, column: :plan_type_id if had_fk
    change_column_null :coplan_plans, :plan_type_id, false
    add_foreign_key :coplan_plans, :coplan_plan_types, column: :plan_type_id if had_fk
  end

  def down
    had_fk = foreign_key_exists?(:coplan_plans, column: :plan_type_id)
    remove_foreign_key :coplan_plans, column: :plan_type_id if had_fk
    change_column_null :coplan_plans, :plan_type_id, true
    add_foreign_key :coplan_plans, :coplan_plan_types, column: :plan_type_id if had_fk
  end
end
