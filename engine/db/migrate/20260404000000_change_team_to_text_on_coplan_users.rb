class ChangeTeamToTextOnCoplanUsers < ActiveRecord::Migration[8.1]
  def up
    change_column :coplan_users, :team, :text
  end

  def down
    change_column :coplan_users, :team, :string
  end
end
