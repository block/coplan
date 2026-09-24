module CoPlan
  module Slack
    class NotificationDeliveryJob < ActiveJob::Base
      class AdapterUnavailable < StandardError; end

      include CoPlan::DebouncedJob

      queue_as :default
      debounces_with window: 2.minutes, retry_horizon: 90.minutes
      retry_on AdapterUnavailable, wait: 1.minute, attempts: 60
      retry_on WebClient::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
        job.fail_pending!(error)
      end

      def perform_batch(key:, batch_start:)
        user_id, thread_id = key.split(":", 2)
        config = CoPlan::Slack.configuration
        raise AdapterUnavailable, "CoPlan Slack notifications are not configured on this worker" unless config.notifications_configured?

        deliveries = pending_for(user_id, thread_id)
          .includes(notification: [ :comment, :plan, :user, :comment_thread ])
          .order("coplan_notifications.created_at", "coplan_notifications.id")
          .to_a
        return if deliveries.empty?

        skipped, deliverable = deliveries.partition { |delivery| delivery.notification.read? || delivery.notification.comment.nil? }
        mark(skipped, status: "skipped")
        return if deliverable.empty?
        @attempted_delivery_ids = deliverable.map(&:id)

        user = deliverable.first.notification.user
        raise WebClient::PermanentError, "CoPlan Slack recipient has no email" if user.email.blank?

        comments = deliverable.map { |delivery| delivery.notification.comment }.uniq(&:id)

        client = WebClient.new(token: config.bot_token)
        response = client.users_lookup_by_email(email: user.email)
        slack_user_id = response.dig("user", "id")
        raise WebClient::PermanentError, "No Slack user found for #{user.email}" if slack_user_id.blank?

        text = message(deliverable.first.notification, comments, config.base_url)
        result = client.chat_post_message(channel: slack_user_id, text: text, mrkdwn: true)
        mark(deliverable, status: "delivered", sent_at: Time.current, external_id: result["ts"])
      rescue WebClient::PermanentError => error
        mark(deliverable, status: "failed", error_code: error.message.to_s.truncate(255)) if deliverable
        Rails.error.report(error, handled: true, context: { recipient_id: user_id, thread_id: thread_id })
      end

      def fail_pending!(error)
        key = arguments.first.with_indifferent_access.fetch(:key)
        user_id, thread_id = key.split(":", 2)
        attempted = CoPlan::NotificationDelivery.pending.where(id: @attempted_delivery_ids).to_a
        mark(attempted, status: "failed", error_code: error.message.to_s.truncate(255))
        self.class.release_debounce(key)
        if (remaining = pending_for(user_id, thread_id).order("coplan_notification_deliveries.created_at").first)
          self.class.debounce(key: key, event_at: remaining.created_at)
        end
        Rails.error.report(error, handled: false, context: { recipient_id: user_id, thread_id: thread_id })
      end

      private

      def pending_for(user_id, thread_id)
        CoPlan::NotificationDelivery.pending.where(channel: "slack")
          .joins(:notification)
          .where(coplan_notifications: { user_id: user_id, comment_thread_id: thread_id })
      end

      def mark(deliveries, **attributes)
        return if deliveries.empty?

        CoPlan::NotificationDelivery.pending.where(id: deliveries.map(&:id)).update_all(**attributes, updated_at: Time.current)
      end

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
