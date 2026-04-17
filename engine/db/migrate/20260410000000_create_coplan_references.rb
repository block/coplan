class CreateCoplanReferences < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_references, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :key
      t.string :url, null: false
      t.string :title
      t.string :reference_type, null: false
      t.string :source, null: false
      t.string :target_plan_id, limit: 36
      t.timestamps
    end

    add_index :coplan_references, [:plan_id, :key], unique: true
    add_index :coplan_references, [:plan_id, :url], unique: true
    add_index :coplan_references, :target_plan_id
    add_index :coplan_references, :source
    add_foreign_key :coplan_references, :coplan_plans, column: :plan_id
    add_foreign_key :coplan_references, :coplan_plans, column: :target_plan_id
  end
end
