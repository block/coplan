require "rails_helper"

RSpec.describe CoPlan::EditSession, type: :model do
  let(:user) { create(:user) }
  let(:plan) { create(:plan, created_by_user: user) }

  describe "validations" do
    it "is valid with valid attributes" do
      session = build(:edit_session, plan: plan)
      expect(session).to be_valid
    end

    it "requires actor_type" do
      session = build(:edit_session, plan: plan, actor_type: nil)
      expect(session).not_to be_valid
      expect(session.errors[:actor_type]).to include("can't be blank")
    end

    it "validates actor_type inclusion" do
      session = build(:edit_session, plan: plan, actor_type: "invalid")
      expect(session).not_to be_valid
      expect(session.errors[:actor_type]).to include("is not included in the list")
    end

    it "requires status" do
      session = build(:edit_session, plan: plan, status: nil)
      expect(session).not_to be_valid
      expect(session.errors[:status]).to include("can't be blank")
    end

    it "validates status inclusion" do
      session = build(:edit_session, plan: plan, status: "invalid")
      expect(session).not_to be_valid
      expect(session.errors[:status]).to include("is not included in the list")
    end

    it "requires base_revision" do
      session = build(:edit_session, plan: plan, base_revision: nil)
      expect(session).not_to be_valid
      expect(session.errors[:base_revision]).to include("can't be blank")
    end

    it "requires expires_at" do
      session = build(:edit_session, plan: plan, expires_at: nil)
      expect(session).not_to be_valid
      expect(session.errors[:expires_at]).to include("can't be blank")
    end
  end

  describe "associations" do
    it "belongs to plan" do
      session = create(:edit_session, plan: plan)
      expect(session.plan).to eq(plan)
    end
  end

  describe "defaults" do
    it "defaults operations_json to empty array" do
      session = CoPlan::EditSession.new
      expect(session.operations_json).to eq([])
    end
  end

  describe "constants" do
    it "has correct LOCAL_AGENT_TTL" do
      expect(CoPlan::EditSession::LOCAL_AGENT_TTL).to eq(10.minutes)
    end

    it "has correct CLOUD_PERSONA_TTL" do
      expect(CoPlan::EditSession::CLOUD_PERSONA_TTL).to eq(30.minutes)
    end
  end

  describe "#open?" do
    it "returns true when status is open" do
      session = build(:edit_session, plan: plan, status: "open")
      expect(session.open?).to be true
    end

    it "returns false when status is not open" do
      session = build(:edit_session, plan: plan, status: "committed")
      expect(session.open?).to be false
    end
  end

  describe "#committed?" do
    it "returns true when status is committed" do
      session = build(:edit_session, plan: plan, status: "committed")
      expect(session.committed?).to be true
    end

    it "returns false when status is not committed" do
      session = build(:edit_session, plan: plan, status: "open")
      expect(session.committed?).to be false
    end
  end

  describe "#expired?" do
    it "returns true when expires_at is past and status is open" do
      session = create(:edit_session, plan: plan, expires_at: 1.minute.ago)
      expect(session.expired?).to be true
    end

    it "returns false when status is committed even if past TTL" do
      session = create(:edit_session, :committed, plan: plan, expires_at: 1.minute.ago)
      expect(session.expired?).to be false
    end

    it "returns false when expires_at is in the future" do
      session = create(:edit_session, plan: plan)
      expect(session.expired?).to be false
    end
  end

  describe "#add_operation" do
    it "appends to operations_json and saves" do
      session = create(:edit_session, plan: plan)
      op = { "op" => "replace_exact", "old_text" => "old", "new_text" => "new" }
      session.add_operation(op)
      session.reload
      expect(session.operations_json).to eq([op])
    end
  end

  describe "#has_operations?" do
    it "returns true when operations exist" do
      session = create(:edit_session, :with_operations, plan: plan)
      expect(session.has_operations?).to be true
    end

    it "returns false when operations are empty" do
      session = create(:edit_session, plan: plan)
      expect(session.has_operations?).to be false
    end
  end

  describe "scopes" do
    describe ".open_sessions" do
      it "returns only open sessions" do
        open_session = create(:edit_session, plan: plan, status: "open")
        create(:edit_session, :committed, plan: plan)

        expect(CoPlan::EditSession.open_sessions).to contain_exactly(open_session)
      end
    end

    describe ".expired_pending" do
      it "returns open sessions past their expires_at" do
        expired = create(:edit_session, plan: plan, expires_at: 1.minute.ago)
        create(:edit_session, plan: plan, expires_at: 10.minutes.from_now)
        create(:edit_session, :committed, plan: plan, expires_at: 1.minute.ago)

        expect(CoPlan::EditSession.expired_pending).to contain_exactly(expired)
      end
    end
  end
end
