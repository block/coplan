require "rails_helper"

RSpec.describe CoPlan::WebPushDeliveryJob, type: :job do
  let(:user)         { create(:coplan_user) }
  let(:subscription) { create(:coplan_web_push_subscription, user: user) }
  let(:plan)         { create(:plan, created_by_user: user) }
  let(:thread) do
    create(:comment_thread,
      plan: plan,
      plan_version: plan.current_plan_version,
      created_by_user: user)
  end
  let!(:comment) do
    thread.comments.create!(
      author_type: "human",
      author_id: user.id,
      body_markdown: "Hi"
    )
  end
  let(:notification) do
    create(:notification,
      user: user, plan: plan, comment_thread: thread, comment: comment, reason: "reply")
  end

  before do
    CoPlan.configuration.vapid_public_key  = "pub"
    CoPlan.configuration.vapid_private_key = "priv"
    CoPlan.configuration.vapid_subject     = "mailto:test@example.com"
  end

  after do
    CoPlan.configuration.vapid_public_key  = nil
    CoPlan.configuration.vapid_private_key = nil
    CoPlan.configuration.vapid_subject     = nil
  end

  describe "#perform" do
    it "calls Deliver with the notification's payload and the subscription" do
      allow(CoPlan::WebPush::Deliver).to receive(:call).and_return(:delivered)

      described_class.perform_now(notification_id: notification.id, subscription_id: subscription.id)

      expect(CoPlan::WebPush::Deliver).to have_received(:call).with(
        subscription: subscription,
        payload: hash_including(:title, :body, :url, :tag)
      )
    end

    it "destroys the subscription when delivery reports :expired" do
      # Eagerly create both rows so the change matcher only counts what the
      # job itself does, not the let-driven setup.
      subscription_id = subscription.id
      notification_id = notification.id
      allow(CoPlan::WebPush::Deliver).to receive(:call).and_return(:expired)

      expect {
        described_class.perform_now(notification_id: notification_id, subscription_id: subscription_id)
      }.to change(CoPlan::WebPushSubscription, :count).by(-1)
    end

    it "no-ops if the notification was already deleted" do
      notification_id = notification.id
      notification.destroy!

      expect {
        described_class.perform_now(notification_id: notification_id, subscription_id: subscription.id)
      }.not_to raise_error
    end

    it "no-ops if the subscription was already deleted" do
      subscription_id = subscription.id
      subscription.destroy!

      expect {
        described_class.perform_now(notification_id: notification.id, subscription_id: subscription_id)
      }.not_to raise_error
    end
  end
end
