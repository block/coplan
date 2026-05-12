require "rails_helper"

RSpec.describe CoPlan::WebPush::Deliver do
  let(:subscription) { create(:coplan_web_push_subscription) }
  let(:payload) { { title: "Hi", body: "Hello", url: "/plans/x", tag: "comment-thread-1" } }

  before do
    CoPlan.configuration.vapid_public_key  = "public"
    CoPlan.configuration.vapid_private_key = "private"
    CoPlan.configuration.vapid_subject     = "mailto:test@example.com"
  end

  after do
    CoPlan.configuration.vapid_public_key  = nil
    CoPlan.configuration.vapid_private_key = nil
    CoPlan.configuration.vapid_subject     = nil
  end

  describe ".call" do
    it "POSTs the payload via the web-push gem and records delivery on success" do
      allow(::WebPush).to receive(:payload_send)

      result = described_class.call(subscription: subscription, payload: payload)

      expect(::WebPush).to have_received(:payload_send).with(
        endpoint: subscription.endpoint,
        p256dh: subscription.p256dh_key,
        auth: subscription.auth_key,
        message: payload.to_json,
        vapid: {
          subject: "mailto:test@example.com",
          public_key: "public",
          private_key: "private"
        },
        ttl: 24 * 60 * 60,
        urgency: "normal"
      )
      expect(result).to eq(:delivered)
      expect(subscription.reload.notifications_delivered_count).to eq(1)
      expect(subscription.last_delivered_at).to be_present
    end

    it "returns :expired when the push service reports the subscription is gone (410)" do
      response = instance_double(Net::HTTPResponse, code: "410", message: "Gone", body: "")
      allow(::WebPush).to receive(:payload_send)
        .and_raise(::WebPush::ExpiredSubscription.new(response, "fcm.googleapis.com"))

      result = described_class.call(subscription: subscription, payload: payload)

      expect(result).to eq(:expired)
      expect(subscription.reload.notifications_delivered_count).to eq(0)
    end

    it "returns :expired for invalid subscription (404)" do
      response = instance_double(Net::HTTPResponse, code: "404", message: "Not Found", body: "")
      allow(::WebPush).to receive(:payload_send)
        .and_raise(::WebPush::InvalidSubscription.new(response, "fcm.googleapis.com"))

      expect(described_class.call(subscription: subscription, payload: payload)).to eq(:expired)
    end

    it "re-raises transient errors so the caller can retry" do
      response = instance_double(Net::HTTPResponse, code: "503", message: "Service Unavailable", body: "")
      allow(::WebPush).to receive(:payload_send)
        .and_raise(::WebPush::PushServiceError.new(response, "fcm.googleapis.com"))

      expect {
        described_class.call(subscription: subscription, payload: payload)
      }.to raise_error(::WebPush::PushServiceError)
    end

    it "raises ConfigurationError when VAPID is not configured" do
      CoPlan.configuration.vapid_private_key = nil

      expect {
        described_class.call(subscription: subscription, payload: payload)
      }.to raise_error(described_class::ConfigurationError)
    end
  end
end
