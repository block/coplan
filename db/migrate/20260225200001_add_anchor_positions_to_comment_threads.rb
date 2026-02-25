class AddAnchorPositionsToCommentThreads < ActiveRecord::Migration[8.1]
  def change
    add_column :comment_threads, :anchor_start, :integer
    add_column :comment_threads, :anchor_end, :integer
    add_column :comment_threads, :anchor_revision, :integer
  end
end
