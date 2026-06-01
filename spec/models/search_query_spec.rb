require "rails_helper"

RSpec.describe CoPlan::SearchQuery, type: :model do
  let(:user) { create(:coplan_user) }

  describe ".log!" do
    it "creates a row for a new query" do
      expect {
        described_class.log!(user: user, query: "auth")
      }.to change { described_class.count }.by(1)
    end

    it "deduplicates by (user, query) and bumps created_at instead of growing" do
      old = freeze_time do
        Time.current.tap { described_class.log!(user: user, query: "auth") }
      end

      travel 5.minutes do
        described_class.log!(user: user, query: "auth")
      end

      rows = described_class.where(user: user, query: "auth")
      expect(rows.count).to eq(1)
      expect(rows.first.created_at).to be > old
    end

    it "ignores blank or whitespace-only queries" do
      expect {
        described_class.log!(user: user, query: "   ")
        described_class.log!(user: user, query: "")
      }.not_to change { described_class.count }
    end

    it "ignores logging when user is nil (signed-out searcher)" do
      expect {
        described_class.log!(user: nil, query: "auth")
      }.not_to change { described_class.count }
    end

    it "ignores queries longer than 255 chars to avoid pathological inputs" do
      expect {
        described_class.log!(user: user, query: "x" * 256)
      }.not_to change { described_class.count }
    end
  end

  describe ".recent_for" do
    it "returns the user's queries newest-first, capped at RECENT_LIMIT" do
      (described_class::RECENT_LIMIT + 5).times do |i|
        travel_to (i + 1).minutes.from_now do
          described_class.log!(user: user, query: "q#{i}")
        end
      end

      results = described_class.recent_for(user).pluck(:query)
      expect(results.size).to eq(described_class::RECENT_LIMIT)
      expect(results.first).to eq("q#{described_class::RECENT_LIMIT + 4}")
    end

    it "scopes by user" do
      other_user = create(:coplan_user)
      described_class.log!(user: user, query: "mine")
      described_class.log!(user: other_user, query: "theirs")

      expect(described_class.recent_for(user).pluck(:query)).to eq(["mine"])
    end
  end
end
