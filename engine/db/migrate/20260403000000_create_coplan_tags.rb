class CreateCoplanTags < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_tags, id: { type: :string, limit: 36 } do |t|
      t.string :name, null: false
      t.integer :plans_count, default: 0, null: false
      t.timestamps
    end

    add_index :coplan_tags, :name, unique: true

    create_table :coplan_plan_tags, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :tag_id, limit: 36, null: false
      t.timestamps
    end

    add_index :coplan_plan_tags, [:plan_id, :tag_id], unique: true
    add_index :coplan_plan_tags, :tag_id
    add_foreign_key :coplan_plan_tags, :coplan_plans, column: :plan_id
    add_foreign_key :coplan_plan_tags, :coplan_tags, column: :tag_id
  end
end
