class MarkClosedThreadNotificationsRead < ActiveRecord::Migration[8.1]
  # Clears the accumulated inbox rows that point at resolved or discarded
  # threads. These are the pile behind "20 unread comments" on a plan whose
  # comments are all settled — the doc view hides a closed thread's
  # highlight, so the rows sent readers to an apparently empty page.
  #
  # Pairs with the behaviour change: closing a thread now sweeps its rows
  # read (CommentThread#mark_notifications_read_if_closed), and agent
  # replies / status changes on an already-closed thread don't notify at
  # all (Notifications::Create::SILENT_ON_CLOSED_THREAD).
  #
  # Idempotent: already-read rows don't match the unread scope. Rows stay
  # in the inbox history — only their unread flag changes.
  def up
    closed_thread_ids = CoPlan::CommentThread
      .where(status: CoPlan::CommentThread::CLOSED_STATUSES)
      .select(:id)

    CoPlan::Notification.unread
      .where(comment_thread_id: closed_thread_ids)
      .update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def down
    # no-op (not reversible — the original read_at values were nil, but
    # re-marking them unread would resurrect exactly the noise this cleared)
  end
end
