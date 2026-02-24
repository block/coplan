class AddAgentNameToComments < ActiveRecord::Migration[8.1]
  def change
    add_column :comments, :agent_name, :string
  end
end
