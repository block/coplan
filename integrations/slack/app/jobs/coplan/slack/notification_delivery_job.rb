module CoPlan
  module Slack
    class NotificationDeliveryJob < ActiveJob::Base
      include CoPlan::DebouncedJob

      queue_as :default
      debounces_with window: 2.minutes
      retry_on WebClient::RetryableError, wait: :polynomially_longer, attempts: 5

      def perform_batch(key:, batch_start:)
        user_id, thread_id = key.split(":", 2)
        config = CoPlan::Slack.configuration
        raise ArgumentError, "CoPlan Slack notifications require bot_token and base_url" unless config.notifications_configured?

        notifications = CoPlan::Notification.unread
          .where(user_id: user_id, comment_thread_id: thread_id, reason: %w[new_comment reply])
          .where(created_at: batch_start..)
          .includes(:comment, :plan, :user, :comment_thread)
          .order(:created_at, :id)
          .to_a
        return if notifications.empty?

        user = notifications.first.user
        if user.email.blank?
          Rails.error.report(ArgumentError.new("CoPlan Slack recipient has no email"), handled: true,
            context: { recipient_id: user_id, thread_id: thread_id })
          return
        end

        comments = notifications.filter_map(&:comment).uniq(&:id)
        return if comments.empty?

        client = WebClient.new(token: config.bot_token)
        response = client.users_lookup_by_email(email: user.email)
        slack_user_id = response.dig("user", "id")
        raise WebClient::PermanentError, "No Slack user found for #{user.email}" if slack_user_id.blank?

        client.chat_post_message(channel: slack_user_id, text: message(notifications.first, comments, config.base_url), mrkdwn: true)
      rescue WebClient::PermanentError => error
        Rails.error.report(error, handled: true, context: { recipient_id: user_id, thread_id: thread_id })
      end

      private

      def message(notification, comments, base_url)
        plan = notification.plan
        title = comments.size == 1 ? "New comment" : "#{comments.size} new comments"
        lines = [ "#{title} on *#{plan.title}*" ]
        anchor = notification.comment_thread.anchor_text
        lines << "> _#{anchor.truncate(120)}_" if anchor.present?
        comments.first(3).each { |comment| lines << "> #{comment.body_markdown.to_s.truncate(300)}" }
        lines << "…and #{comments.size - 3} more" if comments.size > 3
        lines << "#{base_url.chomp('/')}#{CoPlan::Urls::Canonical.plan_path(plan)}"
        lines.join("\n")
      end
    end
  end
end
