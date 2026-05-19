class CreateCoplanPlanEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_plan_events, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :actor_id, limit: 36
      t.string :actor_type, null: false
      t.string :event_type, null: false
      t.string :field
      t.text :before_value
      t.text :after_value
      t.json :metadata
      t.datetime :created_at, null: false

      t.index :plan_id
      t.index [:plan_id, :created_at]
      t.index :event_type
    end
  end
end
