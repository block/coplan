# This migration comes from co_plan (originally 20260327000000)
class CreateCoplanPlanViewers < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_plan_viewers, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :user_id, limit: 36, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
    end

    add_index :coplan_plan_viewers, [:plan_id, :user_id], unique: true
    add_index :coplan_plan_viewers, :last_seen_at
    add_foreign_key :coplan_plan_viewers, :coplan_plans, column: :plan_id
    add_foreign_key :coplan_plan_viewers, :coplan_users, column: :user_id
  end
end
