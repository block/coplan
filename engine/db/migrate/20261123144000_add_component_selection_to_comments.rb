class AddComponentSelectionToComments < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_comments, :component_selection, :json
  end
end
