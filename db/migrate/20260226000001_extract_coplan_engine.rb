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
    # Step 1: Remove organization_id foreign keys
    RENAMES.each_key do |table|
      remove_foreign_key table, :organizations if foreign_key_exists?(table, :organizations)
    end

    # Step 2: Remove ALL indexes containing organization_id (by inspection,
    # not by name — avoids MySQL auto-rename and truncation surprises)
    RENAMES.each_key do |table|
      connection.indexes(table).each do |idx|
        if idx.columns.include?("organization_id")
          remove_index table, name: idx.name
        end
      end
    end

    # Step 3: Remove all single-column indexes on columns we'll re-index
    # after rename. This cleans up pre-existing duplicates (e.g. two unique
    # indexes on automated_plan_reviewers.key) AND prevents MySQL from
    # auto-renaming them during rename_table into names that collide with
    # the ones we add in Step 7.
    cleanup_single_column_indexes(:plans, "status")
    cleanup_single_column_indexes(:plans, "updated_at")
    cleanup_single_column_indexes(:automated_plan_reviewers, "key")

    # Step 4: Drop organization_id column from all engine tables
    RENAMES.each_key do |table|
      remove_column table, :organization_id, :string, limit: 36
    end

    # Step 5: Rename all engine tables to coplan_ prefix
    RENAMES.each do |old_name, new_name|
      rename_table old_name, new_name
    end

    # Step 6: Safety net — remove any indexes MySQL auto-created or
    # auto-renamed during Steps 4–5 on the columns we're about to re-index
    cleanup_single_column_indexes(:coplan_plans, "status")
    cleanup_single_column_indexes(:coplan_plans, "updated_at")
    cleanup_single_column_indexes(:coplan_automated_plan_reviewers, "key")

    # Step 7: Add replacement indexes with clean names
    add_index :coplan_automated_plan_reviewers, :key, unique: true, name: :index_coplan_automated_plan_reviewers_on_key
    add_index :coplan_plans, :status, name: :index_coplan_plans_on_status
    add_index :coplan_plans, :updated_at, name: :index_coplan_plans_on_updated_at
  end

  def down
    # Step 1: Remove replacement indexes
    remove_index :coplan_plans, name: :index_coplan_plans_on_status, if_exists: true
    remove_index :coplan_plans, name: :index_coplan_plans_on_updated_at, if_exists: true
    remove_index :coplan_automated_plan_reviewers, name: :index_coplan_automated_plan_reviewers_on_key, if_exists: true

    # Step 2: Rename tables back
    RENAMES.each do |old_name, new_name|
      rename_table new_name, old_name
    end

    # Step 3: Add organization_id back to all tables
    RENAMES.each_key do |table|
      add_column table, :organization_id, :string, limit: 36
    end

    # Step 4: Restore organization_id indexes
    add_index :plans, :organization_id
    add_index :plans, [:organization_id, :status]
    add_index :plans, [:organization_id, :updated_at]
    add_index :plan_versions, :organization_id
    add_index :comment_threads, :organization_id
    add_index :comments, :organization_id
    add_index :edit_leases, :organization_id
    add_index :edit_sessions, :organization_id
    add_index :plan_collaborators, :organization_id
    add_index :api_tokens, :organization_id
    add_index :automated_plan_reviewers, [:organization_id, :key], unique: true

    # Step 5: Restore foreign keys
    RENAMES.each_key do |table|
      add_foreign_key table, :organizations
    end
  end

  private

  # Remove every index on +table+ whose columns are exactly [column].
  # Uses connection.indexes inspection to avoid name-based lookup failures
  # caused by MySQL auto-renaming indexes during table renames.
  def cleanup_single_column_indexes(table, column)
    connection.indexes(table).each do |idx|
      if idx.columns == [column]
        remove_index table, name: idx.name
      end
    end
  end
end
