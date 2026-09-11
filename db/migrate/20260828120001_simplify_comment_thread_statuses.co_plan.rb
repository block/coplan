class SimplifyCommentThreadStatuses < ActiveRecord::Migration[8.0]
  def up
    # Collapse the accept/reject mechanics into a plain open/resolved toggle:
    # pending and todo (both "not yet resolved") become open; discarded
    # (a rejection outcome) is treated the same as resolved (a closed thread).
    # todo threads carry a resolved_by_user_id from accept! — clear it so an
    # open thread never disagrees with newly created/reopened ones, which
    # have no resolver.
    execute <<~SQL
      UPDATE coplan_comment_threads SET status = 'open', resolved_by_user_id = NULL WHERE status IN ('pending', 'todo')
    SQL
    execute <<~SQL
      UPDATE coplan_comment_threads SET status = 'resolved' WHERE status = 'discarded'
    SQL
    change_column_default :coplan_comment_threads, :status, "open"
  end

  def down
    change_column_default :coplan_comment_threads, :status, "pending"
    # Lossy: todo/discarded can't be distinguished from open/resolved after up.
    execute <<~SQL
      UPDATE coplan_comment_threads SET status = 'pending' WHERE status = 'open'
    SQL
  end
end
