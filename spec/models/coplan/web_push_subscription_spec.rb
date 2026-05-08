require "rails_helper"

RSpec.describe CoPlan::WebPushSubscription, type: :model do
  let(:user) { create(:coplan_user) }

  describe "validations" do
    it "is valid with a factory" do
      expect(build(:coplan_web_push_subscription, user: user)).to be_valid
    end

    it "requires endpoint, p256dh_key, auth_key" do
      sub = described_class.new(user: user)
      expect(sub).not_to be_valid
      expect(sub.errors[:endpoint]).to include("can't be blank")
      expect(sub.errors[:p256dh_key]).to include("can't be blank")
      expect(sub.errors[:auth_key]).to include("can't be blank")
    end

    it "computes endpoint_digest from endpoint" do
      sub = build(:coplan_web_push_subscription, user: user, endpoint: "https://example.com/abc")
      sub.valid?
      expect(sub.endpoint_digest).to eq(Digest::SHA256.hexdigest("https://example.com/abc"))
    end

    it "rejects duplicate endpoint_digest" do
      create(:coplan_web_push_subscription, user: user, endpoint: "https://example.com/abc")
      dup = build(:coplan_web_push_subscription, user: create(:coplan_user), endpoint: "https://example.com/abc")
      expect(dup).not_to be_valid
      expect(dup.errors[:endpoint_digest]).to include("has already been taken")
    end
  end

  describe ".upsert_for" do
    it "creates a new subscription" do
      expect {
        described_class.upsert_for(
          user: user,
          endpoint: "https://example.com/abc",
          p256dh_key: "key",
          auth_key: "auth",
          user_agent: "Test/1.0"
        )
      }.to change(described_class, :count).by(1)
    end

    it "is idempotent on the same endpoint (updates rather than duplicates)" do
      first = described_class.upsert_for(
        user: user, endpoint: "https://example.com/abc",
        p256dh_key: "key1", auth_key: "auth1", user_agent: "Old"
      )
      expect {
        second = described_class.upsert_for(
          user: user, endpoint: "https://example.com/abc",
          p256dh_key: "key2", auth_key: "auth2", user_agent: "New"
        )
        expect(second.id).to eq(first.id)
      }.not_to change(described_class, :count)
      first.reload
      expect(first.p256dh_key).to eq("key2")
      expect(first.user_agent).to eq("New")
    end

    it "updates last_seen_at" do
      sub = described_class.upsert_for(
        user: user, endpoint: "https://example.com/abc",
        p256dh_key: "k", auth_key: "a"
      )
      expect(sub.last_seen_at).to be_within(2.seconds).of(Time.current)
    end
  end

  describe "#record_delivery!" do
    it "increments count and updates last_delivered_at" do
      sub = create(:coplan_web_push_subscription, user: user)
      expect { sub.record_delivery! }.to change { sub.reload.notifications_delivered_count }.by(1)
      expect(sub.last_delivered_at).to be_within(2.seconds).of(Time.current)
    end
  end

  describe "#device_label" do
    {
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36" => "Chrome on macOS",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) Gecko/20100101 Firefox/120.0" => "Firefox on macOS",
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Edg/120.0" => "Edge on Windows",
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1" => "Safari on iOS"
    }.each do |ua, expected|
      it "labels #{expected.inspect} for the matching User-Agent" do
        sub = build(:coplan_web_push_subscription, user: user, user_agent: ua)
        expect(sub.device_label).to eq(expected)
      end
    end

    it "falls back to 'Unknown browser' when blank" do
      sub = build(:coplan_web_push_subscription, user: user, user_agent: nil)
      expect(sub.device_label).to eq("Unknown browser")
    end
  end

  describe "user association" do
    it "is destroyed when user is destroyed" do
      sub = create(:coplan_web_push_subscription, user: user)
      expect { user.destroy }.to change { described_class.where(id: sub.id).count }.from(1).to(0)
    end
  end
end
