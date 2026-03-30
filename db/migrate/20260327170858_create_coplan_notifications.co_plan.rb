# This migration comes from co_plan (originally 20260327000000)
class CreateCoplanNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_notifications, id: { type: :string, limit: 36 } do |t|
      t.string :user_id, limit: 36, null: false
      t.string :plan_id, limit: 36, null: false
      t.string :comment_thread_id, limit: 36, null: false
      t.string :comment_id, limit: 36
      t.string :reason, null: false
      t.timestamp :read_at

      t.timestamps
    end

    add_index :coplan_notifications, [:user_id, :read_at], name: "index_coplan_notifications_on_user_id_and_read_at"
    add_index :coplan_notifications, [:comment_thread_id, :user_id], name: "index_coplan_notifications_on_thread_and_user"
    add_index :coplan_notifications, :plan_id, name: "index_coplan_notifications_on_plan_id"

    add_foreign_key :coplan_notifications, :coplan_users, column: :user_id
    add_foreign_key :coplan_notifications, :coplan_plans, column: :plan_id
    add_foreign_key :coplan_notifications, :coplan_comment_threads, column: :comment_thread_id
    add_foreign_key :coplan_notifications, :coplan_comments, column: :comment_id
  end
end
