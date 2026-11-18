require "rails_helper"

RSpec.describe "Web Push Subscriptions", type: :request do
  let(:user) { create(:coplan_user) }

  before do
    sign_in_as(user)
    allow(CoPlan.configuration).to receive(:web_push_configured?).and_return(true)
  end

  it "renders the mounted subscription route for the browser" do
    get settings_root_path

    meta = Nokogiri::HTML(response.body).at_css("meta[name='coplan-web-push-subscription-url']")
    expect(meta["content"]).to eq(web_push_subscription_path)
  end

  describe "GET /web_push/subscription" do
    it "reports registration for the current account without caching it" do
      sub = create(:coplan_web_push_subscription, user: user)
      get web_push_subscription_path, params: { endpoint_digest: sub.endpoint_digest }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("subscribed" => true)
      expect(response.headers["Cache-Control"]).to include("no-store")

      sub.destroy!
      get web_push_subscription_path, params: { endpoint_digest: sub.endpoint_digest }, as: :json
      expect(response.parsed_body).to eq("subscribed" => false)
    end

    it "does not expose another account's registration" do
      sub = create(:coplan_web_push_subscription)
      get web_push_subscription_path, params: { endpoint_digest: sub.endpoint_digest }, as: :json

      expect(response.parsed_body).to eq("subscribed" => false)
    end

    it "reports an existing subscription outside the delivery cap as inactive" do
      old = create(:coplan_web_push_subscription, user: user, last_seen_at: 1.day.ago)
      create_list(:coplan_web_push_subscription, CoPlan::WebPushSubscription::MAX_PER_USER,
        user: user, last_seen_at: Time.current)
      get web_push_subscription_path, params: { endpoint_digest: old.endpoint_digest }, as: :json

      expect(response.parsed_body).to eq("subscribed" => false)
    end

    it "requires a browser session" do
      reset!
      get web_push_subscription_path, params: { endpoint_digest: "unknown" }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 503 when Web Push is not configured" do
      allow(CoPlan.configuration).to receive(:web_push_configured?).and_return(false)
      get web_push_subscription_path, params: { endpoint_digest: "unknown" }, as: :json

      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe "POST /web_push/subscription" do
    let(:payload) do
      {
        subscription: {
          endpoint: "https://fcm.googleapis.com/fcm/send/abc123",
          keys: { p256dh: "p256dhvalue", auth: "authvalue" }
        }
      }
    end

    it "creates a new subscription scoped to the current user" do
      expect {
        post web_push_subscription_path,
             params: payload.to_json,
             headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.to change { user.web_push_subscriptions.count }.by(1)

      expect(response).to have_http_status(:created)
      sub = user.web_push_subscriptions.last
      expect(sub.endpoint).to eq("https://fcm.googleapis.com/fcm/send/abc123")
      expect(sub.p256dh_key).to eq("p256dhvalue")
      expect(sub.auth_key).to eq("authvalue")
    end

    it "captures the User-Agent header" do
      post web_push_subscription_path,
           params: payload.to_json,
           headers: { "Content-Type" => "application/json", "User-Agent" => "Firefox/Test 99" }
      expect(user.web_push_subscriptions.last.user_agent).to eq("Firefox/Test 99")
    end

    it "is idempotent on duplicate posts (no duplicate row)" do
      post web_push_subscription_path,
           params: payload.to_json,
           headers: { "Content-Type" => "application/json" }
      expect {
        post web_push_subscription_path,
             params: payload.to_json,
             headers: { "Content-Type" => "application/json" }
      }.not_to change { CoPlan::WebPushSubscription.count }
      expect(response).to have_http_status(:created)
    end

    it "returns 503 when Web Push is not configured" do
      allow(CoPlan.configuration).to receive(:web_push_configured?).and_return(false)
      post web_push_subscription_path,
           params: payload.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:service_unavailable)
    end

    it "rejects when not signed in" do
      reset!  # drop session cookie
      post web_push_subscription_path,
           params: payload.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).not_to have_http_status(:created)
    end
  end

  describe "DELETE /web_push/subscription" do
    let!(:sub) { create(:coplan_web_push_subscription, user: user, endpoint: "https://example.com/abc") }

    it "removes the subscription matching the endpoint" do
      expect {
        delete web_push_subscription_path,
               params: { subscription: { endpoint: "https://example.com/abc" } }.to_json,
               headers: { "Content-Type" => "application/json" }
      }.to change { user.web_push_subscriptions.count }.by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "returns 404 if endpoint isn't ours" do
      delete web_push_subscription_path,
             params: { subscription: { endpoint: "https://example.com/not-mine" } }.to_json,
             headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:not_found)
    end

    it "doesn't allow another user's subscription to be deleted" do
      other_user = create(:coplan_user)
      other_sub = create(:coplan_web_push_subscription, user: other_user, endpoint: "https://example.com/other")
      delete web_push_subscription_path,
             params: { subscription: { endpoint: "https://example.com/other" } }.to_json,
             headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:not_found)
      expect(CoPlan::WebPushSubscription.where(id: other_sub.id)).to exist
    end
  end
end
