# This migration comes from co_plan (originally 20260922220000)
class AddCreationKeyToCoplanPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_plans, :creation_key, :string, limit: 36
    add_index :coplan_plans, [ :created_by_user_id, :creation_key ], unique: true, name: "index_coplan_plans_on_author_and_creation_key"
  end
end
