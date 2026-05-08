# This migration comes from co_plan (originally 20260508000000)
class CreateCoplanWebPushSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :coplan_web_push_subscriptions, id: :string, limit: 36 do |t|
      t.string :user_id, null: false, limit: 36
      t.text :endpoint, null: false
      # SHA256 hex digest of endpoint, used for unique constraint since the
      # full endpoint can exceed indexable string limits (FCM endpoints can
      # be 200-400 chars).
      t.string :endpoint_digest, null: false, limit: 64
      t.string :p256dh_key, null: false, limit: 255
      t.string :auth_key, null: false, limit: 100
      t.string :user_agent
      t.datetime :last_seen_at
      t.datetime :last_delivered_at
      t.integer :notifications_delivered_count, null: false, default: 0
      t.timestamps
    end

    add_index :coplan_web_push_subscriptions, :user_id
    add_index :coplan_web_push_subscriptions, :endpoint_digest, unique: true
    add_foreign_key :coplan_web_push_subscriptions, :coplan_users, column: :user_id
  end
end
