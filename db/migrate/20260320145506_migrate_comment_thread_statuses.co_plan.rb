class MigrateCommentThreadStatuses < ActiveRecord::Migration[8.0]
  def up
    # open → pending (default for new comments from non-authors)
    # accepted → resolved (collapse accepted into resolved)
    # dismissed → discarded (rename)
    # resolved stays resolved
    #
    # We also add "todo" as a new status (author agrees with feedback).
    # Existing "open" threads become "pending" since we can't determine authorship here.
    execute <<~SQL
      UPDATE coplan_comment_threads SET status = 'pending' WHERE status = 'open'
    SQL
    execute <<~SQL
      UPDATE coplan_comment_threads SET status = 'discarded' WHERE status = 'dismissed'
    SQL
    execute <<~SQL
      UPDATE coplan_comment_threads SET status = 'resolved' WHERE status = 'accepted'
    SQL
    change_column_default :coplan_comment_threads, :status, "pending"
  end

  def down
    change_column_default :coplan_comment_threads, :status, "open"
    execute <<~SQL
      UPDATE coplan_comment_threads SET status = 'open' WHERE status IN ('pending', 'todo')
    SQL
    execute <<~SQL
      UPDATE coplan_comment_threads SET status = 'dismissed' WHERE status = 'discarded'
    SQL
  end
end
