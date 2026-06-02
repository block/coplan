# This migration comes from co_plan (originally 20260527000000)
class AddDeletedAtToCoplanComments < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_comments, :deleted_at, :datetime
  end
end
