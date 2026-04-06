# This migration comes from co_plan (originally 20260403000000)
class CreateCoplanPlanTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_plan_types, id: { type: :string, limit: 36 } do |t|
      t.string :name, null: false
      t.text :description
      t.json :default_tags
      t.text :template_content
      t.json :metadata
      t.timestamps
    end

    add_index :coplan_plan_types, :name, unique: true

    add_column :coplan_plans, :plan_type_id, :string, limit: 36
    add_index :coplan_plans, :plan_type_id
    add_foreign_key :coplan_plans, :coplan_plan_types, column: :plan_type_id
  end
end
