class AddReactionsVersionToCoplanComments < ActiveRecord::Migration[8.1]
  # Bumped after every reaction change, so pages can tell which of two
  # renders of a comment's reactions is newer.
  def change
    add_column :coplan_comments, :reactions_version, :integer, null: false, default: 0
  end
end
