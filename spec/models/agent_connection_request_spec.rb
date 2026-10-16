require "rails_helper"

RSpec.describe CoPlan::AgentConnectionRequest, type: :model do
  let(:user) { create(:coplan_user) }

  def issue
    described_class.issue!(name: "Work laptop")
  end

  it "stores only digests and looks up a normalized public code" do
    record, secret, code = issue
    expect(record).to be_valid
    expect(record.attributes.values).not_to include(secret, code)
    expect(described_class.for_user_code(code.downcase.delete("-"))).to eq(record)
    expect(record.device_code_digest).to eq(described_class.digest(secret))
    expect(record.expires_at).to be_within(1.second).of(10.minutes.from_now)
  end

  it "validates names and terminal identities" do
    expect { described_class.issue!(name: " ") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { described_class.issue!(name: "a" * 101) }.to raise_error(ActiveRecord::RecordInvalid)
    record, = issue
    record.status = "approved"
    expect(record).not_to be_valid
  end

  it "creates no access before approval and delivers one personal credential" do
    record, = issue
    expect { expect(record.redeem!).to eq(error: "authorization_pending") }.not_to change(CoPlan::ApiToken, :count)
    expect(record.decide!(user: user, approve: true)).to be true
    travel 6.seconds
    result = record.redeem!
    token = CoPlan::ApiToken.authenticate(result.fetch(:token))
    expect(token.user).to eq(user)
    expect(token.name).to eq("Work laptop")
    expect(token).to be_can_mint
    expect(record.reload.status).to eq("consumed")
    expect { expect(record.redeem!).to eq(error: "invalid_grant") }.not_to change(CoPlan::ApiToken, :count)
  end

  it "throttles polling and never lets denial turn into approval" do
    record, = issue
    expect(record.redeem![:error]).to eq("authorization_pending")
    expect(record.redeem![:error]).to eq("slow_down")
    expect(record.decide!(user: user, approve: false)).to be true
    expect(record.decide!(user: user, approve: true)).to be false
    expect(record.redeem!).to eq(error: "access_denied")
    expect(CoPlan::ApiToken.count).to eq(0)
  end

  it "rejects expired requests, including an approval not yet collected" do
    record, = issue
    record.decide!(user: user, approve: true)
    travel 11.minutes
    expect(record.redeem!).to eq(error: "expired_token")
    expect(record.decide!(user: user, approve: true)).to be false
    expect(CoPlan::ApiToken.count).to eq(0)
  end

  it "retains no old approval requests as new connections are requested" do
    record, = issue
    record.update!(expires_at: 2.days.ago)
    issue
    expect(described_class.exists?(record.id)).to be false
  end
end

RSpec.describe "Concurrent connection redemption", type: :model do
  self.use_transactional_tests = false

  it "issues exactly one credential when two pollers redeem an approval together" do
    user = create(:coplan_user)
    request, = CoPlan::AgentConnectionRequest.issue!(name: "Concurrent setup")
    request.decide!(user: user, approve: true)
    gate = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          results << CoPlan::AgentConnectionRequest.find(request.id).redeem!
        end
      end
    end
    2.times { gate << true }
    threads.each(&:value)
    responses = 2.times.map { results.pop }
    expect(responses.count { |result| result[:token] }).to eq(1)
    expect(responses.count { |result| result[:error] == "invalid_grant" }).to eq(1)
    expect(user.api_tokens.count).to eq(1)
  ensure
    threads&.each(&:join)
    user&.destroy!
  end
end
