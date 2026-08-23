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
      expect(response).to redirect_to(plan_page_path(plan, thread: thread.id))

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

  describe "POST /notifications/mark_plan_read" do
    let(:other_plan) { create(:plan, :considering) }
    let(:other_thread) { create(:comment_thread, plan: other_plan, plan_version: other_plan.current_plan_version, created_by_user: user) }

    it "clears one plan's unread rows and leaves the rest" do
      mine = create(:notification, user: user, plan: plan, comment_thread: thread)
      elsewhere = create(:notification, user: user, plan: other_plan, comment_thread: other_thread)

      post mark_plan_read_notifications_path(plan_id: plan.id)

      expect(mine.reload.read_at).to be_present
      expect(elsewhere.reload.read_at).to be_nil
    end

    it "does not touch another user's rows for the same plan" do
      other_user = create(:coplan_user)
      theirs = create(:notification, user: other_user, plan: plan, comment_thread: thread)

      post mark_plan_read_notifications_path(plan_id: plan.id)

      expect(theirs.reload.read_at).to be_nil
    end

    it "responds with a turbo_stream that updates the badge and replaces the strip" do
      create(:notification, user: user, plan: plan, comment_thread: thread)

      post mark_plan_read_notifications_path(plan_id: plan.id),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(Mime[:turbo_stream])
      expect(response.body).to include('target="inbox-badge"')
      expect(response.body).to include('target="needs-attention"')
      expect(response.body).to include(%(target="plan-unread-#{plan.id}"))
      expect(user.notifications.unread.count).to eq(0)
    end

    it "redirects back for a non-turbo request" do
      create(:notification, user: user, plan: plan, comment_thread: thread)

      post mark_plan_read_notifications_path(plan_id: plan.id)

      expect(response).to redirect_to(plans_path)
    end

    it "is a no-op without a plan_id" do
      notification = create(:notification, user: user, plan: plan, comment_thread: thread)

      post mark_plan_read_notifications_path

      expect(notification.reload.read_at).to be_nil
    end
  end
end
