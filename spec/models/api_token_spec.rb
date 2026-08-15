require "rails_helper"

RSpec.describe CoPlan::ApiToken, type: :model do
  let(:user) { create(:coplan_user) }

  it "is valid with valid attributes" do
    token = create(:api_token, user: user)
    expect(token).to be_valid
  end

  it "requires name" do
    token = build(:api_token, user: user, name: nil)
    expect(token).not_to be_valid
    expect(token.errors[:name]).to include("can't be blank")
  end

  it "requires token_digest" do
    token = build(:api_token, user: user, token_digest: nil)
    expect(token).not_to be_valid
    expect(token.errors[:token_digest]).to include("can't be blank")
  end

  it "authenticates with valid token" do
    create(:api_token, user: user, raw_token: "test-token-alice")
    result = CoPlan::ApiToken.authenticate("test-token-alice")
    expect(result).not_to be_nil
  end

  it "returns nil for invalid token" do
    expect(CoPlan::ApiToken.authenticate("invalid-token")).to be_nil
  end

  it "returns nil for revoked token" do
    create(:api_token, :revoked, user: user, raw_token: "test-token-revoked")
    expect(CoPlan::ApiToken.authenticate("test-token-revoked")).to be_nil
  end

  it "returns nil for blank token" do
    expect(CoPlan::ApiToken.authenticate("")).to be_nil
    expect(CoPlan::ApiToken.authenticate(nil)).to be_nil
  end

  it "revoke sets revoked_at" do
    token = create(:api_token, user: user)
    expect(token).not_to be_revoked
    token.revoke!
    expect(token).to be_revoked
    expect(token.revoked_at).not_to be_nil
  end

  it "active? returns false when revoked" do
    token = create(:api_token, :revoked, user: user)
    expect(token).not_to be_active
  end

  it "active? returns true for valid token" do
    token = create(:api_token, user: user)
    expect(token).to be_active
  end

  it "generate_token returns hex string" do
    raw = CoPlan::ApiToken.generate_token
    expect(raw).to match(/\A[0-9a-f]{64}\z/)
  end

  describe "session tokens" do
    let(:parent) { create(:api_token, user: user, name: "hampton-laptop", agent_name: "Claude") }

    it "mints a child that inherits the principal and expires on its own" do
      child, raw = parent.mint_session_token!(agent_name: "Claude refactor")

      expect(child.user_id).to eq(user.id)
      expect(child.parent_id).to eq(parent.id)
      expect(child.agent_name).to eq("Claude refactor")
      expect(child.expires_at).to be_within(1.minute).of(12.hours.from_now)
      expect(CoPlan::ApiToken.authenticate(raw)).to eq(child)
    end

    it "inherits the parent's agent_name when none is given" do
      child, = parent.mint_session_token!
      expect(child.agent_name).to eq("Claude")
    end

    it "clamps the ttl to the maximum" do
      child, = parent.mint_session_token!(ttl: 30.days)
      expect(child.expires_at).to be_within(1.minute).of(described_class::MAX_SESSION_TTL.from_now)
    end

    it "truncates an agent_name past the cap instead of failing" do
      child, = parent.mint_session_token!(agent_name: "An Agent With A Very Long Name Indeed")
      expect(child.agent_name.length).to be <= described_class::AGENT_NAME_LIMIT
    end

    it "does not let a session token mint further tokens" do
      child, = parent.mint_session_token!
      expect(child).not_to be_can_mint
      expect { child.mint_session_token! }
        .to raise_error(CoPlan::ApiToken::Minting::NotPermitted)
    end

    it "revokes its children when the parent is revoked" do
      child, raw = parent.mint_session_token!

      parent.revoke!

      expect(child.reload).to be_revoked
      expect(CoPlan::ApiToken.authenticate(raw)).to be_nil
    end

    it "refuses a child whose parent expired without being revoked" do
      child, raw = parent.mint_session_token!
      parent.update!(expires_at: 1.minute.ago)

      expect(CoPlan::ApiToken.authenticate(raw)).to be_nil
      expect(child.reload).not_to be_revoked
    end
  end

  describe "bootstrap minting (no parent token)" do
    it "mints a parentless session identity for a hook-authenticated user" do
      token, raw = CoPlan::ApiToken.mint_session_token_for!(user: user, agent_name: "Claude")

      expect(token.user_id).to eq(user.id)
      expect(token.parent_id).to be_nil
      expect(token.agent_name).to eq("Claude")
      expect(token.expires_at).to be_within(1.minute).of(12.hours.from_now)
      expect(CoPlan::ApiToken.authenticate(raw)).to eq(token)
    end

    it "cannot mint further tokens despite having no parent — expiry marks it a session" do
      token, = CoPlan::ApiToken.mint_session_token_for!(user: user)
      expect(token).not_to be_can_mint
      expect { token.mint_session_token! }
        .to raise_error(CoPlan::ApiToken::Minting::NotPermitted)
    end
  end
end
