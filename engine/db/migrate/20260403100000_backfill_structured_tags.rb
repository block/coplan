class BackfillStructuredTags < ActiveRecord::Migration[8.1]
  def up
    # Backfill Tag + PlanTag records from JSON tags column
    execute(<<~SQL).each do |row|
      SELECT id, tags FROM coplan_plans WHERE tags IS NOT NULL
    SQL
      plan_id = row[0] || row["id"]
      raw = row[1] || row["tags"]
      next if raw.blank?

      parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
      next unless parsed.is_a?(Array)

      parsed.each do |name|
        name = name.to_s.strip
        next if name.blank?

        tag_id = SecureRandom.uuid_v7
        execute "INSERT IGNORE INTO coplan_tags (id, name, plans_count, created_at, updated_at) VALUES (#{quote(tag_id)}, #{quote(name)}, 0, NOW(), NOW())"
        actual_tag_id = select_value("SELECT id FROM coplan_tags WHERE name = #{quote(name)}")
        pt_id = SecureRandom.uuid_v7
        execute "INSERT IGNORE INTO coplan_plan_tags (id, plan_id, tag_id, created_at, updated_at) VALUES (#{quote(pt_id)}, #{quote(plan_id)}, #{quote(actual_tag_id)}, NOW(), NOW())"
      end
    end

    # Reset counter caches
    execute <<~SQL
      UPDATE coplan_tags SET plans_count = (
        SELECT COUNT(*) FROM coplan_plan_tags WHERE coplan_plan_tags.tag_id = coplan_tags.id
      )
    SQL

    remove_column :coplan_plans, :tags
  end

  def down
    add_column :coplan_plans, :tags, :json
  end
end
