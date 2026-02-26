require "rails_helper"

RSpec.describe CoPlan::EditLease, type: :model do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:api_token) { create(:api_token, user: user) }
  let(:lease_token) { SecureRandom.hex(32) }

  it "acquire creates new lease" do
    lease = CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: api_token.id,
      lease_token: lease_token
    )
    expect(lease).to be_persisted
    expect(lease).to be_held
    expect(lease.plan_id).to eq(plan.id)
  end

  it "acquire replaces expired lease" do
    CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: api_token.id,
      lease_token: lease_token
    )

    lease = CoPlan::EditLease.find_by(plan_id: plan.id)
    lease.update!(expires_at: 1.minute.ago)

    other_token = create(:api_token, user: user)
    new_token = SecureRandom.hex(32)
    new_lease = CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: other_token.id,
      lease_token: new_token
    )
    expect(new_lease).to be_persisted
    expect(new_lease).to be_held
  end

  it "acquire raises conflict when held by another" do
    CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: api_token.id,
      lease_token: lease_token
    )

    other_token = create(:api_token, user: user)
    expect {
      CoPlan::EditLease.acquire!(
        plan: plan,
        holder_type: "local_agent",
        holder_id: other_token.id,
        lease_token: SecureRandom.hex(32)
      )
    }.to raise_error(CoPlan::EditLease::Conflict)
  end

  it "acquire with same token renews lease" do
    lease = CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: api_token.id,
      lease_token: lease_token
    )
    original_expires = lease.expires_at

    travel 1.minute do
      renewed = CoPlan::EditLease.acquire!(
        plan: plan,
        holder_type: "local_agent",
        holder_id: api_token.id,
        lease_token: lease_token
      )
      expect(renewed.expires_at).to be > original_expires
    end
  end

  it "renew updates expiry" do
    lease = CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: api_token.id,
      lease_token: lease_token
    )

    travel 1.minute do
      lease.renew!(lease_token: lease_token)
      expect(lease.expires_at).to be > Time.current
    end
  end

  it "renew raises conflict with wrong token" do
    lease = CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: api_token.id,
      lease_token: lease_token
    )

    expect {
      lease.renew!(lease_token: "wrong-token")
    }.to raise_error(CoPlan::EditLease::Conflict)
  end

  it "release destroys lease" do
    lease = CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: api_token.id,
      lease_token: lease_token
    )

    lease.release!(lease_token: lease_token)
    expect(CoPlan::EditLease.find_by(plan_id: plan.id)).to be_nil
  end

  it "release raises conflict with wrong token" do
    lease = CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: api_token.id,
      lease_token: lease_token
    )

    expect {
      lease.release!(lease_token: "wrong-token")
    }.to raise_error(CoPlan::EditLease::Conflict)
  end

  it "held_by? checks token and expiry" do
    lease = CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: api_token.id,
      lease_token: lease_token
    )

    expect(lease.held_by?(lease_token: lease_token)).to be true
    expect(lease.held_by?(lease_token: "wrong-token")).to be false
  end
end
