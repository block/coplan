# This migration comes from co_plan (originally 20261029000000)
class CreateCoplanCommentReactions < ActiveRecord::Migration[8.1]
  # One row per person per reaction on a comment. `kind` stores a key from
  # CommentReaction::KINDS ("thumbs_up"), never the emoji itself: the
  # comments tables use an accent-insensitive collation that can treat
  # distinct emoji as equal and break the unique index.
  def change
    create_table :coplan_comment_reactions, id: { type: :string, limit: 36 } do |t|
      t.string :comment_id, limit: 36, null: false
      t.string :user_id, limit: 36, null: false
      t.string :kind, null: false
      t.timestamps
    end

    add_index :coplan_comment_reactions, [ :comment_id, :user_id, :kind ],
      unique: true, name: "index_coplan_comment_reactions_on_comment_user_kind"
    add_index :coplan_comment_reactions, :user_id
    add_foreign_key :coplan_comment_reactions, :coplan_comments, column: :comment_id
    add_foreign_key :coplan_comment_reactions, :coplan_users, column: :user_id
  end
end
