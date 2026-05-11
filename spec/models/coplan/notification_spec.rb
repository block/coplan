require "rails_helper"

RSpec.describe CoPlan::Notification do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:thread) do
    create(:comment_thread,
      plan: plan,
      plan_version: plan.current_plan_version,
      created_by_user: user)
  end
  let(:attrs) do
    { user: user, plan: plan, comment_thread: thread, reason: "reply" }
  end

  describe "after_create web push fan-out" do
    context "when web push is configured" do
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

      it "enqueues one delivery job per subscription on create" do
        sub_a = create(:coplan_web_push_subscription, user: user)
        sub_b = create(:coplan_web_push_subscription, user: user)

        expect {
          described_class.create!(attrs)
        }.to have_enqueued_job(CoPlan::WebPushDeliveryJob).twice

        notification = described_class.last
        [sub_a, sub_b].each do |sub|
          expect(CoPlan::WebPushDeliveryJob).to have_been_enqueued.with(
            notification_id: notification.id,
            subscription_id: sub.id
          )
        end
      end

      it "enqueues nothing when the recipient has no subscriptions" do
        expect {
          described_class.create!(attrs)
        }.not_to have_enqueued_job(CoPlan::WebPushDeliveryJob)
      end

      it "does not enqueue on update" do
        create(:coplan_web_push_subscription, user: user)
        notification = described_class.create!(attrs)

        expect {
          notification.mark_read!
        }.not_to have_enqueued_job(CoPlan::WebPushDeliveryJob)
      end
    end

    context "when web push is not configured" do
      it "does not enqueue any jobs even if subscriptions exist" do
        # Sanity: in test env VAPID keys are nil by default.
        create(:coplan_web_push_subscription, user: user)

        expect {
          described_class.create!(attrs)
        }.not_to have_enqueued_job(CoPlan::WebPushDeliveryJob)
      end
    end
  end
end
