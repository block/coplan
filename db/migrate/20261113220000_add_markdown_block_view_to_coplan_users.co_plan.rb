# This migration comes from co_plan (originally 20261113000000)
class AddMarkdownBlockViewToCoplanUsers < ActiveRecord::Migration[8.1]
  # Which view a markdown or md fence opens in on the reading view.
  def change
    add_column :coplan_users, :markdown_block_view, :string, null: false, default: "rendered"
  end
end
