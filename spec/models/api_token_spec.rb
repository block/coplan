require "rails_helper"

RSpec.describe ApiToken, type: :model do
  let(:org) { create(:organization) }
  let(:user) { create(:user, organization: org) }

  it "is valid with valid attributes" do
    token = create(:api_token, organization: org, user: user)
    expect(token).to be_valid
  end

  it "requires name" do
    token = build(:api_token, organization: org, user: user, name: nil)
    expect(token).not_to be_valid
    expect(token.errors[:name]).to include("can't be blank")
  end

  it "requires token_digest" do
    token = build(:api_token, organization: org, user: user, token_digest: nil)
    expect(token).not_to be_valid
    expect(token.errors[:token_digest]).to include("can't be blank")
  end

  it "authenticates with valid token" do
    create(:api_token, organization: org, user: user, raw_token: "test-token-alice")
    result = ApiToken.authenticate("test-token-alice")
    expect(result).not_to be_nil
  end

  it "returns nil for invalid token" do
    expect(ApiToken.authenticate("invalid-token")).to be_nil
  end

  it "returns nil for revoked token" do
    create(:api_token, :revoked, organization: org, user: user, raw_token: "test-token-revoked")
    expect(ApiToken.authenticate("test-token-revoked")).to be_nil
  end

  it "returns nil for blank token" do
    expect(ApiToken.authenticate("")).to be_nil
    expect(ApiToken.authenticate(nil)).to be_nil
  end

  it "revoke sets revoked_at" do
    token = create(:api_token, organization: org, user: user)
    expect(token).not_to be_revoked
    token.revoke!
    expect(token).to be_revoked
    expect(token.revoked_at).not_to be_nil
  end

  it "active? returns false when revoked" do
    token = create(:api_token, :revoked, organization: org, user: user)
    expect(token).not_to be_active
  end

  it "active? returns true for valid token" do
    token = create(:api_token, organization: org, user: user)
    expect(token).to be_active
  end

  it "generate_token returns hex string" do
    raw = ApiToken.generate_token
    expect(raw).to match(/\A[0-9a-f]{64}\z/)
  end
end
