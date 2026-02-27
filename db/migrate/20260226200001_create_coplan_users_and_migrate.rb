class CreateCoplanUsersAndMigrate < ActiveRecord::Migration[8.1]
  def up
    # Table created by engine migration; migrate existing users data
    execute <<~SQL
      INSERT INTO coplan_users (id, external_id, name, admin, metadata, created_at, updated_at)
      SELECT id, id, name, (role = 'admin'), '{}', created_at, updated_at
      FROM users
    SQL

    # Update foreign keys to point to coplan_users instead of users
    remove_foreign_key :coplan_api_tokens, column: :user_id
    remove_foreign_key :coplan_comment_threads, column: :created_by_user_id
    remove_foreign_key :coplan_comment_threads, column: :resolved_by_user_id
    remove_foreign_key :coplan_plan_collaborators, column: :user_id
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
    remove_foreign_key :coplan_api_tokens, column: :user_id
    remove_foreign_key :coplan_comment_threads, column: :created_by_user_id
    remove_foreign_key :coplan_comment_threads, column: :resolved_by_user_id
    remove_foreign_key :coplan_plan_collaborators, column: :user_id
    remove_foreign_key :coplan_plan_collaborators, column: :added_by_user_id
    remove_foreign_key :coplan_plans, column: :created_by_user_id

    add_foreign_key :coplan_api_tokens, :users, column: :user_id
    add_foreign_key :coplan_comment_threads, :users, column: :created_by_user_id
    add_foreign_key :coplan_comment_threads, :users, column: :resolved_by_user_id
    add_foreign_key :coplan_plan_collaborators, :users, column: :user_id
    add_foreign_key :coplan_plan_collaborators, :users, column: :added_by_user_id
    add_foreign_key :coplan_plans, :users, column: :created_by_user_id
  end
end
