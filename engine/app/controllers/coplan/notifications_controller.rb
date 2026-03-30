module CoPlan
  class NotificationsController < ApplicationController
    def index
      @filter = params[:filter] == "all" ? "all" : "unread"
      @notifications = current_user.notifications
        .includes(:plan, :comment, comment_thread: [:created_by_user])
        .newest_first

      @notifications = @notifications.unread if @filter == "unread"
      @unread_count = current_user.notifications.unread.count

      if params[:panel].present?
        render partial: "coplan/notifications/panel", layout: false
      end
    end

    def show
      notification = current_user.notifications.find(params[:id])
      notification.mark_read!
      broadcast_badge_update

      redirect_to plan_path(notification.plan, thread: notification.comment_thread_id)
    end

    def mark_read
      notification = current_user.notifications.find(params[:id])
      notification.mark_read!

      broadcast_badge_update

      respond_to do |format|
        format.turbo_stream {
          render turbo_stream: turbo_stream.replace(
            ActionView::RecordIdentifier.dom_id(notification),
            partial: "coplan/notifications/notification",
            locals: { notification: notification }
          )
        }
        format.html { redirect_to notifications_path }
      end
    end

    def mark_all_read
      current_user.notifications.unread.update_all(read_at: Time.current)

      broadcast_badge_update

      redirect_to notifications_path, notice: "All notifications marked as read."
    end

    private

    def broadcast_badge_update
      count = current_user.notifications.unread.count
      Broadcaster.update_to(
        "coplan_notifications:#{current_user.id}",
        target: "inbox-badge",
        html: count.to_s
      )
    end
  end
end
