require "rails_helper"

RSpec.describe "Notifications", type: :request do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering) }
  let(:thread) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: user) }

  before do
    sign_in_as(user)
    allow(CoPlan::Broadcaster).to receive(:update_to)
  end

  describe "GET /notifications" do
    it "shows unread notifications by default" do
      unread = create(:notification, user: user, plan: plan, comment_thread: thread)
      create(:notification, user: user, plan: plan, comment_thread: thread, read_at: Time.current)

      get notifications_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(plan.title)
    end

    it "shows all notifications when filtered" do
      create(:notification, user: user, plan: plan, comment_thread: thread, read_at: Time.current)

      get notifications_path(filter: "all")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(plan.title)
    end

    it "shows empty state when no notifications" do
      get notifications_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No unread notifications")
    end
  end

  describe "GET /notifications/:id (show — click-through)" do
    it "marks the notification as read and redirects to the plan with thread param" do
      notification = create(:notification, user: user, plan: plan, comment_thread: thread)

      get notification_path(notification)
      expect(response).to redirect_to(plan_path(plan, thread: thread.id))

      notification.reload
      expect(notification.read_at).to be_present
    end
  end

  describe "PATCH /notifications/:id/mark_read" do
    it "marks a notification as read" do
      notification = create(:notification, user: user, plan: plan, comment_thread: thread)

      patch mark_read_notification_path(notification)
      expect(response).to redirect_to(notifications_path)

      notification.reload
      expect(notification.read_at).to be_present
    end

    it "cannot mark another user's notification" do
      other_user = create(:coplan_user)
      notification = create(:notification, user: other_user, plan: plan, comment_thread: thread)

      patch mark_read_notification_path(notification)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /notifications/mark_all_read" do
    it "marks all unread notifications as read" do
      create(:notification, user: user, plan: plan, comment_thread: thread)
      create(:notification, user: user, plan: plan, comment_thread: thread, reason: "reply")

      post mark_all_read_notifications_path
      expect(response).to redirect_to(notifications_path)
      expect(user.notifications.unread.count).to eq(0)
    end

    it "does not affect other users' notifications" do
      other_user = create(:coplan_user)
      other_notification = create(:notification, user: other_user, plan: plan, comment_thread: thread)

      post mark_all_read_notifications_path
      expect(other_notification.reload.read_at).to be_nil
    end

    it "responds with a turbo_stream that updates the badge and replaces the inbox panel" do
      create(:notification, user: user, plan: plan, comment_thread: thread)

      post mark_all_read_notifications_path, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(Mime[:turbo_stream])
      expect(response.body).to include('target="inbox-badge"')
      expect(response.body).to include('action="update"')
      expect(response.body).to include('target="inbox-panel"')
      expect(response.body).to include('action="replace"')
      expect(user.notifications.unread.count).to eq(0)
    end
  end
end
