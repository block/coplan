module CoPlan
  class NotificationsController < ApplicationController
    # A long-lived account accumulates notifications forever; the inbox
    # only ever shows the most recent page of them.
    INDEX_LIMIT = 100

    def index
      @filter = params[:filter] == "all" ? "all" : "unread"
      @notifications = current_user.notifications
        .includes(:plan, :comment, comment_thread: [ :created_by_user ])
        .newest_first
        .limit(INDEX_LIMIT)

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

      respond_to do |format|
        format.turbo_stream {
          @notifications = current_user.notifications
            .includes(:plan, :comment, comment_thread: [ :created_by_user ])
            .newest_first
            .unread
          @unread_count = 0
          render turbo_stream: [
            turbo_stream.update("inbox-badge", "0"),
            turbo_stream.replace("inbox-panel", partial: "coplan/notifications/panel")
          ]
        }
        format.html { redirect_to notifications_path, notice: "All notifications marked as read." }
      end
    end

    # The dismiss "✕" on a workspace attention row: one plan's unread rows
    # marked read without opening it (opening it does the same thing). The
    # strip re-renders rather than dropping the row, because clearing one
    # plan can promote the next one into view.
    def mark_plan_read
      plan_id = params[:plan_id].to_s
      Notifications::MarkPlanRead.call(user: current_user, plan_id: plan_id)

      respond_to do |format|
        format.turbo_stream do
          attention = Notifications::NeedsAttention.call(user: current_user)
          render turbo_stream: [
            turbo_stream.update("inbox-badge", current_user.notifications.unread.count.to_s),
            turbo_stream.replace("needs-attention", partial: "coplan/plans/needs_attention", locals: { attention: attention }),
            # The plan's own row badge, if that row is on screen — a row
            # still reading "3" after the strip cleared looks stale.
            turbo_stream.remove(helpers.plan_unread_badge_id(plan_id))
          ]
        end
        format.html { redirect_back fallback_location: plans_path, notice: "Notifications cleared." }
      end
    end

    private

    def broadcast_badge_update
      Notifications::BroadcastBadges.call(user_ids: [ current_user.id ])
    end
  end
end
