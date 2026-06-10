class AddDeletedAtToCoplanComments < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_comments, :deleted_at, :datetime
  end
end
