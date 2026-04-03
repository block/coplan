require "rails_helper"

RSpec.describe CoPlan::User, type: :model do
  it "is valid with valid attributes" do
    user = create(:coplan_user)
    expect(user).to be_valid
  end

  it "requires external_id" do
    user = build(:coplan_user, external_id: nil)
    expect(user).not_to be_valid
    expect(user.errors[:external_id]).to include("can't be blank")
  end

  it "requires name" do
    user = build(:coplan_user, name: nil)
    expect(user).not_to be_valid
    expect(user.errors[:name]).to include("can't be blank")
  end

  it "defaults notification_preferences to empty hash" do
    user = CoPlan::User.new
    expect(user.notification_preferences).to eq({})
  end

  it "defaults metadata to empty hash" do
    user = CoPlan::User.new
    expect(user.metadata).to eq({})
  end

  it "persists profile fields" do
    user = create(:coplan_user,
      avatar_url: "https://example.com/avatar.png",
      title: "Staff Engineer",
      team: "Platform"
    )
    user.reload
    expect(user.avatar_url).to eq("https://example.com/avatar.png")
    expect(user.title).to eq("Staff Engineer")
    expect(user.team).to eq("Platform")
  end

  it "persists notification_preferences" do
    user = create(:coplan_user, notification_preferences: { "slack" => true })
    user.reload
    expect(user.notification_preferences).to eq("slack" => true)
  end
end
