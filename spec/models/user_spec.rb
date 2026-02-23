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

  it "validates email uniqueness within organization" do
    existing = create(:user)
    user = build(:user, organization: existing.organization, email: existing.email)
    expect(user).not_to be_valid
    expect(user.errors[:email]).to include("has already been taken")
  end

  it "allows same email in different orgs" do
    org1 = create(:organization, allowed_email_domains: ["test.com"])
    org2 = create(:organization, allowed_email_domains: ["test.com"])
    create(:user, organization: org1, email: "same@test.com")
    user = build(:user, organization: org2, email: "same@test.com")
    expect(user).to be_valid
  end

  it "validates org_role inclusion" do
    user = build(:user, org_role: "superadmin")
    expect(user).not_to be_valid
    expect(user.errors[:org_role]).to include("is not included in the list")
  end

  it "returns true for admin?" do
    user = create(:user, :admin)
    expect(user).to be_admin
  end

  it "returns false for admin? when member" do
    user = create(:user, org_role: "member")
    expect(user).not_to be_admin
  end

  it "validates email domain against org allowed domains" do
    org = create(:organization, allowed_email_domains: ["acme.com"])
    user = build(:user, organization: org, email: "user@other.com")
    expect(user).not_to be_valid
    expect(user.errors[:email]).to include("domain is not allowed for this organization")
  end

  it "extracts email domain" do
    user = build(:user, email: "alice@example.com")
    expect(user.email_domain).to eq("example.com")
  end
end
