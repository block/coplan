class CreateCoplanSchema < ActiveRecord::Migration[8.1]
  def change
    # Skip if tables already exist (transition from auto-inject to copied migrations)
    return if table_exists?(:coplan_users)

    create_table :coplan_users, id: { type: :string, limit: 36 } do |t|
      t.string :external_id, null: false
      t.string :email
      t.string :name, null: false
      t.boolean :admin, default: false, null: false
      t.json :metadata
      t.timestamps
    end

    add_index :coplan_users, :external_id, unique: true
    add_index :coplan_users, :email, unique: true

    create_table :coplan_plans, id: { type: :string, limit: 36 } do |t|
      t.string :title, null: false
      t.string :status, default: "brainstorm", null: false
      t.integer :current_revision, default: 0, null: false
      t.string :created_by_user_id, limit: 36, null: false
      t.string :current_plan_version_id, limit: 36
      t.json :tags
      t.json :metadata
      t.timestamps
    end

    add_index :coplan_plans, :status
    add_index :coplan_plans, :updated_at
    add_index :coplan_plans, :created_by_user_id
    add_foreign_key :coplan_plans, :coplan_users, column: :created_by_user_id

    create_table :coplan_plan_versions, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.integer :revision, null: false
      t.text :content_markdown, null: false
      t.string :content_sha256, null: false
      t.text :diff_unified
      t.text :change_summary
      t.text :reason
      t.text :prompt_excerpt
      t.json :operations_json
      t.integer :base_revision
      t.string :actor_id, limit: 36
      t.string :actor_type, null: false
      t.string :ai_provider
      t.string :ai_model
      t.timestamp :created_at, null: false
    end

    add_index :coplan_plan_versions, :plan_id
    add_index :coplan_plan_versions, [:plan_id, :revision], unique: true
    add_index :coplan_plan_versions, [:plan_id, :created_at]
    add_foreign_key :coplan_plan_versions, :coplan_plans, column: :plan_id

    # Now that coplan_plan_versions exists, add the FK for current_plan_version_id
    add_foreign_key :coplan_plans, :coplan_plan_versions, column: :current_plan_version_id

    create_table :coplan_plan_collaborators, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :user_id, limit: 36, null: false
      t.string :added_by_user_id, limit: 36
      t.string :role, null: false
      t.timestamps
    end

    add_index :coplan_plan_collaborators, :plan_id
    add_index :coplan_plan_collaborators, :user_id
    add_index :coplan_plan_collaborators, :added_by_user_id
    add_index :coplan_plan_collaborators, [:plan_id, :user_id], unique: true
    add_foreign_key :coplan_plan_collaborators, :coplan_plans, column: :plan_id
    add_foreign_key :coplan_plan_collaborators, :coplan_users, column: :user_id
    add_foreign_key :coplan_plan_collaborators, :coplan_users, column: :added_by_user_id

    create_table :coplan_comment_threads, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :plan_version_id, limit: 36, null: false
      t.string :created_by_user_id, limit: 36, null: false
      t.string :resolved_by_user_id, limit: 36
      t.string :addressed_in_plan_version_id, limit: 36
      t.string :out_of_date_since_version_id, limit: 36
      t.string :status, default: "open", null: false
      t.boolean :out_of_date, default: false, null: false
      t.text :anchor_text
      t.text :anchor_context
      t.integer :anchor_start
      t.integer :anchor_end
      t.integer :anchor_revision
      t.integer :start_line
      t.integer :end_line
      t.timestamps
    end

    add_index :coplan_comment_threads, [:plan_id, :status]
    add_index :coplan_comment_threads, [:plan_id, :out_of_date]
    add_foreign_key :coplan_comment_threads, :coplan_plans, column: :plan_id
    add_foreign_key :coplan_comment_threads, :coplan_plan_versions, column: :plan_version_id
    add_foreign_key :coplan_comment_threads, :coplan_plan_versions, column: :addressed_in_plan_version_id
    add_foreign_key :coplan_comment_threads, :coplan_plan_versions, column: :out_of_date_since_version_id
    add_foreign_key :coplan_comment_threads, :coplan_users, column: :created_by_user_id
    add_foreign_key :coplan_comment_threads, :coplan_users, column: :resolved_by_user_id

    create_table :coplan_comments, id: { type: :string, limit: 36 } do |t|
      t.string :comment_thread_id, limit: 36, null: false
      t.string :author_id, limit: 36
      t.string :author_type, null: false
      t.string :agent_name
      t.text :body_markdown, null: false
      t.timestamps
    end

    add_index :coplan_comments, [:comment_thread_id, :created_at]
    add_foreign_key :coplan_comments, :coplan_comment_threads, column: :comment_thread_id

    create_table :coplan_edit_leases, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :holder_id, limit: 36
      t.string :holder_type, null: false
      t.string :lease_token_digest, null: false
      t.timestamp :expires_at, null: false
      t.timestamp :last_heartbeat_at, null: false
      t.timestamps
    end

    add_index :coplan_edit_leases, :plan_id, unique: true
    add_foreign_key :coplan_edit_leases, :coplan_plans, column: :plan_id

    create_table :coplan_edit_sessions, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :plan_version_id, limit: 36
      t.string :actor_id, limit: 36
      t.string :actor_type, null: false
      t.string :status, default: "open", null: false
      t.integer :base_revision, null: false
      t.text :draft_content, size: :long
      t.text :change_summary
      t.json :operations_json, null: false
      t.timestamp :expires_at, null: false
      t.timestamp :committed_at
      t.timestamps
    end

    add_index :coplan_edit_sessions, [:plan_id, :status]
    add_foreign_key :coplan_edit_sessions, :coplan_plans, column: :plan_id
    add_foreign_key :coplan_edit_sessions, :coplan_plan_versions, column: :plan_version_id

    create_table :coplan_api_tokens, id: { type: :string, limit: 36 } do |t|
      t.string :user_id, limit: 36, null: false
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, limit: 8
      t.timestamp :expires_at
      t.timestamp :revoked_at
      t.timestamp :last_used_at
      t.timestamps
    end

    add_index :coplan_api_tokens, :user_id
    add_index :coplan_api_tokens, :token_digest, unique: true
    add_foreign_key :coplan_api_tokens, :coplan_users, column: :user_id

    create_table :coplan_automated_plan_reviewers, id: { type: :string, limit: 36 } do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.text :prompt_text, null: false
      t.string :ai_provider, default: "openai", null: false
      t.string :ai_model, null: false
      t.json :trigger_statuses, null: false
      t.boolean :enabled, default: true, null: false
      t.timestamps
    end

    add_index :coplan_automated_plan_reviewers, :key, unique: true
  end
end
