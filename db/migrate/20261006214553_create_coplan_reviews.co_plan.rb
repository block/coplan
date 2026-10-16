# This migration comes from co_plan (originally 20261007000000)
class CreateCoplanReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_review_requests, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :reviewer_id, limit: 36, null: false
      t.string :requested_by_user_id, limit: 36, null: false
      t.string :requested_plan_version_id, limit: 36, null: false
      t.string :requirement, null: false
      t.string :status, null: false
      t.datetime :requested_at, null: false
      t.timestamps
    end
    add_index :coplan_review_requests, [ :plan_id, :reviewer_id ], unique: true
    add_index :coplan_review_requests, [ :reviewer_id, :status ]
    add_foreign_key :coplan_review_requests, :coplan_plans, column: :plan_id
    add_foreign_key :coplan_review_requests, :coplan_users, column: :reviewer_id
    add_foreign_key :coplan_review_requests, :coplan_users, column: :requested_by_user_id
    add_foreign_key :coplan_review_requests, :coplan_plan_versions, column: :requested_plan_version_id

    create_table :coplan_review_responses, id: { type: :string, limit: 36 } do |t|
      t.string :review_request_id, limit: 36, null: false
      t.string :plan_version_id, limit: 36, null: false
      t.string :user_id, limit: 36, null: false
      t.string :decision, null: false
      t.string :actor_type, null: false
      t.string :agent_name, limit: 20
      t.string :api_token_id, limit: 36
      t.string :comment_thread_id, limit: 36
      t.text :note
      t.datetime :created_at, null: false
    end
    add_index :coplan_review_responses, [ :review_request_id, :created_at ], name: "index_coplan_review_responses_on_request_and_created"
    add_foreign_key :coplan_review_responses, :coplan_review_requests, column: :review_request_id
    add_foreign_key :coplan_review_responses, :coplan_plan_versions, column: :plan_version_id
    add_foreign_key :coplan_review_responses, :coplan_users, column: :user_id
    add_foreign_key :coplan_review_responses, :coplan_api_tokens, column: :api_token_id, on_delete: :nullify
    add_foreign_key :coplan_review_responses, :coplan_comment_threads, column: :comment_thread_id, on_delete: :nullify

    change_column_null :coplan_notifications, :comment_thread_id, true
    add_column :coplan_notifications, :review_request_id, :string, limit: 36
    add_index :coplan_notifications, :review_request_id
    add_foreign_key :coplan_notifications, :coplan_review_requests, column: :review_request_id, on_delete: :cascade
    reversible do |direction|
      direction.down do
        # Review-only notifications have no thread. Remove their delivery
        # rows before restoring the older mandatory-thread constraint.
        execute "DELETE FROM coplan_notification_deliveries WHERE notification_id IN (SELECT id FROM coplan_notifications WHERE review_request_id IS NOT NULL)"
        execute "DELETE FROM coplan_notifications WHERE review_request_id IS NOT NULL"
      end
    end
  end
end
