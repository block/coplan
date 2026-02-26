class ExtractCoplanEngine < ActiveRecord::Migration[8.1]
  RENAMES = {
    plans: :coplan_plans,
    plan_versions: :coplan_plan_versions,
    comment_threads: :coplan_comment_threads,
    comments: :coplan_comments,
    edit_leases: :coplan_edit_leases,
    edit_sessions: :coplan_edit_sessions,
    plan_collaborators: :coplan_plan_collaborators,
    api_tokens: :coplan_api_tokens,
    automated_plan_reviewers: :coplan_automated_plan_reviewers,
  }.freeze

  def up
    # Step 1: Rename all engine tables to coplan_ prefix
    RENAMES.each do |old_name, new_name|
      rename_table old_name, new_name
    end

    # Step 2: Remove organization_id foreign keys from all engine tables
    RENAMES.each_value do |table|
      if foreign_key_exists?(table, :organizations)
        remove_foreign_key table, :organizations
      end
    end

    # Step 3: Remove organization_id indexes before dropping the column
    # plans
    remove_index :coplan_plans, name: :index_plans_on_organization_id, if_exists: true
    remove_index :coplan_plans, name: :index_plans_on_organization_id_and_status, if_exists: true
    remove_index :coplan_plans, name: :index_plans_on_organization_id_and_updated_at, if_exists: true

    # plan_versions
    remove_index :coplan_plan_versions, name: :index_plan_versions_on_organization_id, if_exists: true

    # comment_threads
    remove_index :coplan_comment_threads, name: :fk_rails_d5cb7ddf86, if_exists: true

    # comments
    remove_index :coplan_comments, name: :fk_rails_b5b64d6bc9, if_exists: true

    # edit_leases
    remove_index :coplan_edit_leases, name: :fk_rails_3f7fc284d2, if_exists: true

    # edit_sessions
    remove_index :coplan_edit_sessions, name: :index_edit_sessions_on_organization_id, if_exists: true

    # plan_collaborators
    remove_index :coplan_plan_collaborators, name: :index_plan_collaborators_on_organization_id, if_exists: true

    # api_tokens
    remove_index :coplan_api_tokens, name: :fk_rails_701d89e8df, if_exists: true

    # automated_plan_reviewers — replace composite unique index
    remove_index :coplan_automated_plan_reviewers, name: :index_automated_plan_reviewers_on_organization_id_and_key, if_exists: true
    add_index :coplan_automated_plan_reviewers, :key, unique: true, name: :index_coplan_automated_plan_reviewers_on_key

    # Step 4: Drop organization_id column from all engine tables
    RENAMES.each_value do |table|
      remove_column table, :organization_id, :string, limit: 36
    end

    # Step 5: Add replacement indexes for plans (without organization_id)
    add_index :coplan_plans, :status, name: :index_coplan_plans_on_status
    add_index :coplan_plans, :updated_at, name: :index_coplan_plans_on_updated_at
  end

  def down
    # Step 1: Add organization_id back to all engine tables
    RENAMES.each_value do |table|
      add_column table, :organization_id, :string, limit: 36
    end

    # Step 2: Remove replacement indexes on plans
    remove_index :coplan_plans, name: :index_coplan_plans_on_status, if_exists: true
    remove_index :coplan_plans, name: :index_coplan_plans_on_updated_at, if_exists: true

    # Step 3: Restore organization_id indexes
    add_index :coplan_plans, :organization_id, name: :index_plans_on_organization_id
    add_index :coplan_plans, [:organization_id, :status], name: :index_plans_on_organization_id_and_status
    add_index :coplan_plans, [:organization_id, :updated_at], name: :index_plans_on_organization_id_and_updated_at
    add_index :coplan_plan_versions, :organization_id, name: :index_plan_versions_on_organization_id
    add_index :coplan_comment_threads, :organization_id, name: :fk_rails_d5cb7ddf86
    add_index :coplan_comments, :organization_id, name: :fk_rails_b5b64d6bc9
    add_index :coplan_edit_leases, :organization_id, name: :fk_rails_3f7fc284d2
    add_index :coplan_edit_sessions, :organization_id, name: :index_edit_sessions_on_organization_id
    add_index :coplan_plan_collaborators, :organization_id, name: :index_plan_collaborators_on_organization_id
    add_index :coplan_api_tokens, :organization_id, name: :fk_rails_701d89e8df

    # Restore automated_plan_reviewers composite unique index
    remove_index :coplan_automated_plan_reviewers, name: :index_coplan_automated_plan_reviewers_on_key, if_exists: true
    add_index :coplan_automated_plan_reviewers, [:organization_id, :key], unique: true, name: :index_automated_plan_reviewers_on_organization_id_and_key

    # Step 4: Restore foreign keys
    RENAMES.each_value do |table|
      add_foreign_key table, :organizations
    end

    # Step 5: Rename tables back
    RENAMES.each do |old_name, new_name|
      rename_table new_name, old_name
    end
  end
end
