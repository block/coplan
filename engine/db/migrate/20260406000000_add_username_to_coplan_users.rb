class AddUsernameToCoplanUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_users, :username, :string
    add_index :coplan_users, :username, unique: true
  end
end
