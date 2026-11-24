require "rails_helper"

RSpec.describe Coplan::WebPush::Deliver do
  let(:subscription) { create(:coplan_web_push_subscription) }
  let(:payload) { { title: "Hi", body: "Hello", url: "/plans/x", tag: "comment-thread-1" } }

  before do
    Coplan.configuration.vapid_public_key  = "public"
    Coplan.configuration.vapid_private_key = "private"
    Coplan.configuration.vapid_subject     = "mailto:test@example.com"
  end

  after do
    Coplan.configuration.vapid_public_key  = nil
    Coplan.configuration.vapid_private_key = nil
    Coplan.configuration.vapid_subject     = nil
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
        urgency: "normal",
        open_timeout: 5,
        read_timeout: 5,
        ssl_timeout: 5
      )
      expect(result).to eq(:delivered)
      expect(subscription.reload.notifications_delivered_count).to eq(1)
      expect(subscription.last_delivered_at).to be_present
    end

    it "gives the push request 5 s timeouts instead of Net::HTTP's 60 s defaults" do
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      %i[use_ssl= open_timeout= read_timeout= ssl_timeout=].each { |setter| allow(http).to receive(setter) }
      allow(http).to receive(:request).and_return(Net::HTTPCreated.new("1.1", "201", "Created"))
      # Skip VAPID signing and payload encryption; only the transport settings matter here.
      allow_any_instance_of(::WebPush::Request).to receive(:build_payload).and_return({})
      allow_any_instance_of(::WebPush::Request).to receive(:headers).and_return({})
      allow_any_instance_of(::WebPush::Request).to receive(:body).and_return("")

      expect(described_class.call(subscription: subscription, payload: payload)).to eq(:delivered)

      expect(http).to have_received(:open_timeout=).with(5)
      expect(http).to have_received(:read_timeout=).with(5)
      expect(http).to have_received(:ssl_timeout=).with(5)
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
      Coplan.configuration.vapid_private_key = nil

      expect {
        described_class.call(subscription: subscription, payload: payload)
      }.to raise_error(described_class::ConfigurationError)
    end
  end
end
