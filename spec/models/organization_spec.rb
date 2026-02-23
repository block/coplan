require "rails_helper"

RSpec.describe Organization, type: :model do
  it "is valid with valid attributes" do
    org = create(:organization)
    expect(org).to be_valid
  end

  it "requires name" do
    org = build(:organization, name: nil)
    expect(org).not_to be_valid
    expect(org.errors[:name]).to include("can't be blank")
  end

  it "requires slug" do
    org = build(:organization, slug: nil)
    expect(org).not_to be_valid
    expect(org.errors[:slug]).to include("can't be blank")
  end

  it "validates slug uniqueness" do
    existing = create(:organization)
    org = build(:organization, slug: existing.slug)
    expect(org).not_to be_valid
    expect(org.errors[:slug]).to include("has already been taken")
  end

  it "rejects uppercase slugs" do
    org = build(:organization, slug: "BadSlug")
    expect(org).not_to be_valid
    expect(org.errors[:slug]).to include("only allows lowercase letters, numbers, and hyphens")
  end

  it "returns true for allowed email domain" do
    org = create(:organization, allowed_email_domains: ["acme.com"])
    expect(org.email_domain_allowed?("user@acme.com")).to be true
  end

  it "returns false for disallowed email domain" do
    org = create(:organization, allowed_email_domains: ["acme.com"])
    expect(org.email_domain_allowed?("user@other.com")).to be false
  end

  it "checks email domain case-insensitively" do
    org = create(:organization, allowed_email_domains: ["acme.com"])
    expect(org.email_domain_allowed?("user@ACME.COM")).to be true
  end

  it "defaults allowed_email_domains to empty array" do
    org = Organization.new
    expect(org.allowed_email_domains).to eq([])
  end
end
