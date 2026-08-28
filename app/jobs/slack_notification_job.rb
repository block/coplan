class SlackNotificationJob < ApplicationJob
  queue_as :default

  retry_on SlackClient::Error, wait: :polynomially_longer, attempts: 5

  DEBOUNCE_WINDOW = 2.minutes
  CACHE_EXPIRY = DEBOUNCE_WINDOW + 1.minute
  # retry_on below can span several minutes across its 5 attempts of
  # polynomially-longer backoff — give batch/notified state room to outlive
  # every retry, not just the debounce wait, or a late retry falls back to
  # the wrong window or forgets who it already notified.
  RETRY_STATE_EXPIRY = 30.minutes

  # Coalesces a burst of comments on the same thread (e.g. an agent posting
  # several in a row) into a single delayed job. The first call in a window
  # records where the batch starts and schedules the send; later calls
  # within the window are no-ops because a send is already scheduled — the
  # eventual perform picks up everything created since the batch started.
  #
  # batch_start is the triggering comment's own created_at, not the dispatch
  # time this method runs at — this method is always called from a job
  # that's already been enqueued and dequeued for a comment that already
  # exists, so Time.current here would be later than that comment's
  # created_at and silently exclude it from its own notification.
  def self.debounce(comment_thread_id:, comment_created_at: nil)
    pending_key = pending_key(comment_thread_id)
    started = Rails.cache.write(pending_key, true, expires_in: CACHE_EXPIRY, unless_exist: true)
    return unless started

    Rails.cache.write(batch_start_key(comment_thread_id), comment_created_at, expires_in: RETRY_STATE_EXPIRY)
    Rails.cache.delete(notified_key(comment_thread_id))
    set(wait: DEBOUNCE_WINDOW).perform_later(comment_thread_id: comment_thread_id)
  end

  def self.pending_key(comment_thread_id)
    "slack_notification_job:pending:#{comment_thread_id}"
  end

  def self.batch_start_key(comment_thread_id)
    "slack_notification_job:batch_start:#{comment_thread_id}"
  end

  def self.notified_key(comment_thread_id)
    "slack_notification_job:notified:#{comment_thread_id}"
  end

  def perform(comment_thread_id:)
    send_batch(comment_thread_id)
    # Only release the pending flag once the batch fully sends. A transient
    # error (see retry_on above) skips this line, keeping the flag set so a
    # comment arriving mid-retry doesn't start a second, overlapping batch
    # that clobbers this one's batch_start/notified cache state.
    Rails.cache.delete(self.class.pending_key(comment_thread_id))
  end

  private

  def send_batch(comment_thread_id)
    return unless SlackClient.configured?

    thread = CoPlan::CommentThread.find_by(id: comment_thread_id)
    return unless thread

    batch_start = Rails.cache.read(self.class.batch_start_key(comment_thread_id)) || DEBOUNCE_WINDOW.ago
    new_comments = thread.comments.kept.where("coplan_comments.created_at >= ?", batch_start).order(:created_at, :id).to_a
    return if new_comments.empty?

    plan = thread.plan
    recipients = recipients_for(thread, plan, new_comments)
    return if recipients.empty?

    text = compose_message(thread, plan, new_comments)
    notified_key = self.class.notified_key(comment_thread_id)
    already_notified = Rails.cache.read(notified_key) || []

    # A transient error retries the whole job (see retry_on above); track who
    # already got a DM this batch so a retry doesn't double-notify recipients
    # that succeeded before the recipient that raised.
    recipients.each do |user|
      next unless user.email.present?
      next if already_notified.include?(user.id)

      send_dm(user, text)
      already_notified << user.id
      Rails.cache.write(notified_key, already_notified, expires_in: RETRY_STATE_EXPIRY)
    end
  end

  # Everyone who's part of the conversation: the plan owner, plus anyone
  # who's commented in the thread. A participant is skipped only if every
  # comment in this batch is their own — if someone else said something
  # new, they still hear about it even if they also commented in the batch.
  def recipients_for(thread, plan, new_comments)
    participant_ids = thread.comments.kept.where(author_type: %w[human local_agent]).distinct.pluck(:author_id)
    participant_ids = (participant_ids + [ plan.created_by_user_id ]).uniq

    users_by_id = CoPlan::User.where(id: participant_ids).index_by(&:id)
    participant_ids.filter_map do |user_id|
      next unless new_comments.any? { |c| c.author_id != user_id }
      users_by_id[user_id]
    end
  end

  # A permanent failure for one recipient (e.g. no Slack account for their
  # email) shouldn't stop the rest of the batch from being notified.
  def send_dm(user, text)
    SlackClient.send_dm(email: user.email, text: text)
  rescue SlackClient::PermanentError => e
    Rails.logger.warn("[SlackNotificationJob] skipping #{user.id}: #{e.message}")
  end

  def compose_message(thread, plan, new_comments)
    plan_url = CoPlan::Engine.routes.url_helpers.plan_url(plan, **default_url_options)
    latest_body = (new_comments.last.body_markdown || "").truncate(300)

    lines = [
      new_comments.size == 1 ? "New comment on *#{plan.title}*:" : "#{new_comments.size} new comments on *#{plan.title}*:"
    ]
    if thread.anchor_text.present?
      lines << "> _#{thread.anchor_text.truncate(120)}_"
    end
    lines << "> #{latest_body}"
    lines << plan_url
    lines.join("\n")
  end

  def default_url_options
    Rails.application.config.action_mailer.default_url_options || { host: "localhost", port: 3000 }
  end
end
