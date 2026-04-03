# This migration comes from co_plan (originally 20260403000000)
class AddProfileFieldsToCoplanUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_users, :avatar_url, :string
    add_column :coplan_users, :title, :string
    add_column :coplan_users, :team, :string
    add_column :coplan_users, :notification_preferences, :json
  end
end
