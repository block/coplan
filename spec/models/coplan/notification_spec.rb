require "rails_helper"

RSpec.describe Coplan::Notification do
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
        Coplan.configuration.vapid_public_key  = "pub"
        Coplan.configuration.vapid_private_key = "priv"
        Coplan.configuration.vapid_subject     = "mailto:test@example.com"
      end

      after do
        Coplan.configuration.vapid_public_key  = nil
        Coplan.configuration.vapid_private_key = nil
        Coplan.configuration.vapid_subject     = nil
      end

      it "enqueues one delivery job per subscription on create" do
        sub_a = create(:coplan_web_push_subscription, user: user)
        sub_b = create(:coplan_web_push_subscription, user: user)

        expect {
          described_class.create!(attrs)
        }.to have_enqueued_job(Coplan::WebPushDeliveryJob).twice

        notification = described_class.last
        [ sub_a, sub_b ].each do |sub|
          expect(Coplan::WebPushDeliveryJob).to have_been_enqueued.with(
            notification_id: notification.id,
            subscription_id: sub.id
          )
        end
      end

      it "enqueues nothing when the recipient has no subscriptions" do
        expect {
          described_class.create!(attrs)
        }.not_to have_enqueued_job(Coplan::WebPushDeliveryJob)
      end

      it "bounds fan-out for subscriptions registered before the cap existed" do
        create_list(:coplan_web_push_subscription, Coplan::WebPushSubscription::MAX_PER_USER + 3, user: user)

        expect {
          described_class.create!(attrs)
        }.to have_enqueued_job(Coplan::WebPushDeliveryJob).exactly(Coplan::WebPushSubscription::MAX_PER_USER).times
      end

      it "does not enqueue on update" do
        create(:coplan_web_push_subscription, user: user)
        notification = described_class.create!(attrs)

        expect {
          notification.mark_read!
        }.not_to have_enqueued_job(Coplan::WebPushDeliveryJob)
      end
    end

    context "when web push is not configured" do
      it "does not enqueue any jobs even if subscriptions exist" do
        # Sanity: in test env VAPID keys are nil by default.
        create(:coplan_web_push_subscription, user: user)

        expect {
          described_class.create!(attrs)
        }.not_to have_enqueued_job(Coplan::WebPushDeliveryJob)
      end
    end
  end
end
