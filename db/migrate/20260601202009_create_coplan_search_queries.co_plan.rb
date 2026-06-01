# This migration comes from co_plan (originally 20260601000001)
class CreateCoplanSearchQueries < ActiveRecord::Migration[8.1]
  # Records the search queries each user runs, so the search modal can show a
  # "Recent searches" list when the input is empty. We only persist queries for
  # signed-in users; anonymous searches are not logged.
  def change
    create_table :coplan_search_queries, id: { type: :string, limit: 36 } do |t|
      t.string :user_id, limit: 36, null: false
      t.string :query, null: false, limit: 255
      t.timestamp :created_at, null: false
    end

    add_index :coplan_search_queries, [:user_id, :created_at]
    add_foreign_key :coplan_search_queries, :coplan_users, column: :user_id
  end
end
