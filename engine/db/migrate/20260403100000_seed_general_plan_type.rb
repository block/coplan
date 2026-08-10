class SeedGeneralPlanType < ActiveRecord::Migration[8.1]
  def up
    general_id = SecureRandom.uuid_v7
    execute <<~SQL
      INSERT INTO coplan_plan_types (id, name, description, default_tags, template_content, metadata, created_at, updated_at)
      VALUES (#{quote(general_id)}, 'General', 'General-purpose plan', '[]', NULL, '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL

    execute <<~SQL
      UPDATE coplan_plans SET plan_type_id = #{quote(general_id)} WHERE plan_type_id IS NULL
    SQL
  end

  def down
    # select_value, not execute: raw execute result rows are arrays on
    # mysql2 but hashes on pg, so indexing into them isn't portable.
    general_id = connection.select_value("SELECT id FROM coplan_plan_types WHERE name = 'General' LIMIT 1")
    if general_id
      execute("UPDATE coplan_plans SET plan_type_id = NULL WHERE plan_type_id = #{quote(general_id)}")
      execute("DELETE FROM coplan_plan_types WHERE id = #{quote(general_id)}")
    end
  end
end
