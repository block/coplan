class AddMarkdownBlockViewToCoplanUsers < ActiveRecord::Migration[8.1]
  # Which view a markdown or md fence opens in on the reading view.
  def change
    add_column :coplan_users, :markdown_block_view, :string, null: false, default: "rendered"
  end
end
