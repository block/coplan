# This migration comes from co_plan (originally 20260716000000)
class CreateCoplanFolders < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_folders, id: { type: :string, limit: 36 } do |t|
      t.string :name, null: false
      t.string :parent_id, limit: 36
      t.string :created_by_user_id, limit: 36
      t.timestamps

      # Unique per sibling group. MySQL treats NULLs as distinct in unique
      # indexes, so root-level (parent_id IS NULL) uniqueness is enforced by
      # the model validation instead — same approach either way for app code.
      t.index [:parent_id, :name], unique: true
      t.index :created_by_user_id
    end

    add_column :coplan_plans, :folder_id, :string, limit: 36
    add_index :coplan_plans, :folder_id

    add_foreign_key :coplan_folders, :coplan_folders, column: :parent_id
    add_foreign_key :coplan_folders, :coplan_users, column: :created_by_user_id
    add_foreign_key :coplan_plans, :coplan_folders, column: :folder_id
  end
end
