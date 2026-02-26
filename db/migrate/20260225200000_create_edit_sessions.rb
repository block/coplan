class CreateEditSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :edit_sessions, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :organization_id, limit: 36, null: false
      t.string :actor_type, null: false
      t.string :actor_id, limit: 36
      t.string :status, null: false, default: "open"
      t.integer :base_revision, null: false
      t.text :change_summary
      t.json :operations_json, null: false
      t.text :draft_content, size: :long
      t.timestamp :expires_at, null: false
      t.timestamp :committed_at
      t.string :plan_version_id, limit: 36
      t.timestamps
    end

    add_index :edit_sessions, [:plan_id, :status]
    add_index :edit_sessions, :organization_id
    add_foreign_key :edit_sessions, :plans
    add_foreign_key :edit_sessions, :organizations
    add_foreign_key :edit_sessions, :plan_versions
  end
end
