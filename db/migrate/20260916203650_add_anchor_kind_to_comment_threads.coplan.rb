# This migration comes from coplan (originally 20260916120000)
class AddAnchorKindToCommentThreads < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_comment_threads, :anchor_kind, :string
  end
end
