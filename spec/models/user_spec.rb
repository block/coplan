require "rails_helper"

RSpec.describe User, type: :model do
  it "is valid with valid attributes" do
    user = create(:user)
    expect(user).to be_valid
  end

  it "requires email" do
    user = build(:user, email: nil)
    expect(user).not_to be_valid
    expect(user.errors[:email]).to include("can't be blank")
  end

  it "requires name" do
    user = build(:user, name: nil)
    expect(user).not_to be_valid
    expect(user.errors[:name]).to include("can't be blank")
  end

  it "validates email uniqueness" do
    existing = create(:user)
    user = build(:user, email: existing.email)
    expect(user).not_to be_valid
    expect(user.errors[:email]).to include("has already been taken")
  end

  it "validates role inclusion" do
    user = build(:user, role: "superadmin")
    expect(user).not_to be_valid
    expect(user.errors[:role]).to include("is not included in the list")
  end

  it "returns true for admin?" do
    user = create(:user, :admin)
    expect(user).to be_admin
  end

  it "returns false for admin? when member" do
    user = create(:user, role: "member")
    expect(user).not_to be_admin
  end

  it "extracts email domain" do
    user = build(:user, email: "alice@example.com")
    expect(user.email_domain).to eq("example.com")
  end
end
