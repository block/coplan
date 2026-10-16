# This migration comes from co_plan (originally 20261016100000)
class CreateCoplanAgentConnectionRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_agent_connection_requests, id: :string, limit: 36 do |t|
      t.string :name, null: false, limit: 100
      t.string :status, null: false, default: "pending"
      t.string :device_code_digest, null: false
      t.string :user_code_digest, null: false
      t.string :user_id, limit: 36
      t.datetime :expires_at, null: false
      t.datetime :last_polled_at
      t.timestamps
    end
    add_index :coplan_agent_connection_requests, :device_code_digest, unique: true
    add_index :coplan_agent_connection_requests, :user_code_digest, unique: true
    add_index :coplan_agent_connection_requests, :expires_at
    add_index :coplan_agent_connection_requests, :user_id
    add_foreign_key :coplan_agent_connection_requests, :coplan_users, column: :user_id
  end
end
