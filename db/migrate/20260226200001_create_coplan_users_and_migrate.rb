class CreateCoplanUsersAndMigrate < ActiveRecord::Migration[8.1]
  def up
    create_table :coplan_users, id: { type: :string, limit: 36 } do |t|
      t.string :external_id, null: false
      t.string :name, null: false
      t.boolean :admin, default: false, null: false
      t.json :metadata, default: {}
      t.timestamps
    end

    add_index :coplan_users, :external_id, unique: true

    # Migrate existing users — reuse the same id so FK columns stay valid
    execute <<~SQL
      INSERT INTO coplan_users (id, external_id, name, admin, metadata, created_at, updated_at)
      SELECT id, id, name, (role = 'admin'), '{}', created_at, updated_at
      FROM users
    SQL

    # Update foreign keys to point to coplan_users instead of users
    remove_foreign_key :coplan_api_tokens, :users
    remove_foreign_key :coplan_comment_threads, column: :created_by_user_id
    remove_foreign_key :coplan_comment_threads, column: :resolved_by_user_id
    remove_foreign_key :coplan_plan_collaborators, :users
    remove_foreign_key :coplan_plan_collaborators, column: :added_by_user_id
    remove_foreign_key :coplan_plans, column: :created_by_user_id

    add_foreign_key :coplan_api_tokens, :coplan_users, column: :user_id
    add_foreign_key :coplan_comment_threads, :coplan_users, column: :created_by_user_id
    add_foreign_key :coplan_comment_threads, :coplan_users, column: :resolved_by_user_id
    add_foreign_key :coplan_plan_collaborators, :coplan_users, column: :user_id
    add_foreign_key :coplan_plan_collaborators, :coplan_users, column: :added_by_user_id
    add_foreign_key :coplan_plans, :coplan_users, column: :created_by_user_id
  end

  def down
    remove_foreign_key :coplan_api_tokens, :coplan_users
    remove_foreign_key :coplan_comment_threads, column: :created_by_user_id
    remove_foreign_key :coplan_comment_threads, column: :resolved_by_user_id
    remove_foreign_key :coplan_plan_collaborators, :coplan_users
    remove_foreign_key :coplan_plan_collaborators, column: :added_by_user_id
    remove_foreign_key :coplan_plans, column: :created_by_user_id

    add_foreign_key :coplan_api_tokens, :users
    add_foreign_key :coplan_comment_threads, :users, column: :created_by_user_id
    add_foreign_key :coplan_comment_threads, :users, column: :resolved_by_user_id
    add_foreign_key :coplan_plan_collaborators, :users
    add_foreign_key :coplan_plan_collaborators, :users, column: :added_by_user_id
    add_foreign_key :coplan_plans, :users, column: :created_by_user_id

    drop_table :coplan_users
  end
end
