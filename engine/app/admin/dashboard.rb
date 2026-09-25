ActiveAdmin.register_page "Dashboard" do
  menu priority: 1

  content title: "CoPlan administration" do
    since = 7.days.ago
    counts = CoPlan::NotificationDelivery.where(created_at: since..).group(:status).count
    slack_messages = CoPlan::NotificationDelivery.where(channel: "slack", status: "delivered", sent_at: since..)
      .where.not(external_id: nil).distinct.count(:external_id)

    panel "Notification delivery · last 7 days" do
      para "#{CoPlan::Notification.where(created_at: since..).count} notification intents created"
      para "#{helpers.pluralize(slack_messages, 'Slack message')} sent"
      para "Outcomes for deliveries created in the last 7 days (one row per notification and channel):"
      ul do
        CoPlan::NotificationDelivery::STATUSES.each do |status|
          li "#{status.capitalize}: #{counts.fetch(status, 0)}"
        end
      end
      para link_to("View notifications", admin_notifications_path)
      para link_to("View delivery attempts", admin_notification_deliveries_path)
    end

    panel "Recent delivery failures" do
      failures = CoPlan::NotificationDelivery.where(status: "failed").order(updated_at: :desc).limit(10)
      if failures.exists?
        table_for failures do
          column :created_at
          column :channel
          column :error_code
          column("Delivery") { |delivery| link_to(delivery.id, admin_notification_delivery_path(delivery)) }
        end
      else
        para "No failed deliveries."
      end
    end
  end
end
