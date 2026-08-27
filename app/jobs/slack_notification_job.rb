class SlackNotificationJob < ApplicationJob
  queue_as :default

  retry_on SlackClient::Error, wait: :polynomially_longer, attempts: 5

  DEBOUNCE_WINDOW = 2.minutes
  CACHE_EXPIRY = DEBOUNCE_WINDOW + 1.minute

  # Coalesces a burst of comments on the same thread (e.g. an agent posting
  # several in a row) into a single delayed job. The first call in a window
  # records where the batch starts and schedules the send; later calls
  # within the window are no-ops because a send is already scheduled — the
  # eventual perform picks up everything created since the batch started.
  def self.debounce(comment_thread_id:)
    pending_key = pending_key(comment_thread_id)
    return if Rails.cache.read(pending_key)

    Rails.cache.write(pending_key, true, expires_in: CACHE_EXPIRY)
    Rails.cache.write(batch_start_key(comment_thread_id), Time.current, expires_in: CACHE_EXPIRY)
    set(wait: DEBOUNCE_WINDOW).perform_later(comment_thread_id: comment_thread_id)
  end

  def self.pending_key(comment_thread_id)
    "slack_notification_job:pending:#{comment_thread_id}"
  end

  def self.batch_start_key(comment_thread_id)
    "slack_notification_job:batch_start:#{comment_thread_id}"
  end

  def perform(comment_thread_id:)
    Rails.cache.delete(self.class.pending_key(comment_thread_id))
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
    recipients.each do |user|
      next unless user.email.present?
      send_dm(user, text)
    end
  end

  private

  # Everyone who's part of the conversation: the plan owner, plus anyone
  # who's commented in the thread. A participant is skipped only if every
  # comment in this batch is their own — if someone else said something
  # new, they still hear about it even if they also commented in the batch.
  def recipients_for(thread, plan, new_comments)
    participant_ids = thread.comments.where(author_type: %w[human local_agent]).distinct.pluck(:author_id)
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
