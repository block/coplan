require "rails_helper"

RSpec.describe CoPlan::Notification, type: :model do
  it "is valid with valid attributes" do
    notification = create(:notification)
    expect(notification).to be_valid
  end

  it "validates reason presence" do
    notification = build(:notification, reason: "")
    expect(notification).not_to be_valid
  end

  it "validates reason inclusion" do
    notification = build(:notification, reason: "unknown")
    expect(notification).not_to be_valid
  end

  describe "scopes" do
    let(:user) { create(:coplan_user) }
    let(:plan) { create(:plan) }
    let(:thread) { create(:comment_thread, plan: plan) }

    it "unread returns notifications without read_at" do
      unread = create(:notification, user: user, plan: plan, comment_thread: thread, read_at: nil)
      create(:notification, user: user, plan: plan, comment_thread: thread, read_at: Time.current)
      expect(CoPlan::Notification.unread).to eq([unread])
    end

    it "read returns notifications with read_at" do
      create(:notification, user: user, plan: plan, comment_thread: thread, read_at: nil)
      read_notif = create(:notification, user: user, plan: plan, comment_thread: thread, read_at: Time.current)
      expect(CoPlan::Notification.read).to eq([read_notif])
    end
  end

  describe "#mark_read!" do
    it "sets read_at" do
      notification = create(:notification)
      expect(notification.read_at).to be_nil
      notification.mark_read!
      expect(notification.reload.read_at).to be_present
    end

    it "does not update if already read" do
      notification = create(:notification, read_at: 1.hour.ago)
      original_read_at = notification.read_at
      notification.mark_read!
      expect(notification.reload.read_at).to be_within(1.second).of(original_read_at)
    end
  end

  describe "#read?" do
    it "returns false when read_at is nil" do
      notification = build(:notification, read_at: nil)
      expect(notification.read?).to be false
    end

    it "returns true when read_at is set" do
      notification = build(:notification, read_at: Time.current)
      expect(notification.read?).to be true
    end
  end
end
