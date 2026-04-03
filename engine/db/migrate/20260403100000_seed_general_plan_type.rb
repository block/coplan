class SeedGeneralPlanType < ActiveRecord::Migration[8.1]
  def up
    general_id = SecureRandom.uuid_v7
    execute <<~SQL
      INSERT INTO coplan_plan_types (id, name, description, default_tags, template_content, metadata, created_at, updated_at)
      VALUES (#{quote(general_id)}, 'General', 'General-purpose plan', '[]', NULL, '{}', NOW(), NOW())
    SQL

    execute <<~SQL
      UPDATE coplan_plans SET plan_type_id = #{quote(general_id)} WHERE plan_type_id IS NULL
    SQL
  end

  def down
    general = execute("SELECT id FROM coplan_plan_types WHERE name = 'General' LIMIT 1")
    if general.any?
      general_id = general.first[0]
      execute("UPDATE coplan_plans SET plan_type_id = NULL WHERE plan_type_id = #{quote(general_id)}")
      execute("DELETE FROM coplan_plan_types WHERE id = #{quote(general_id)}")
    end
  end
end
