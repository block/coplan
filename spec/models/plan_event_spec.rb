require "rails_helper"

RSpec.describe CoPlan::PlanEvent, type: :model do
  let(:plan) { create(:plan) }

  describe "validations" do
    it "requires actor_type" do
      event = build(:plan_event, actor_type: nil)
      expect(event).not_to be_valid
      expect(event.errors[:actor_type]).to be_present
    end

    it "rejects unknown actor_type values" do
      event = build(:plan_event, actor_type: "spider")
      expect(event).not_to be_valid
      expect(event.errors[:actor_type]).to be_present
    end

    it "requires event_type" do
      event = build(:plan_event, event_type: nil)
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to be_present
    end

    it "rejects unknown event_type values" do
      event = build(:plan_event, event_type: "exploded")
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to be_present
    end
  end

  describe "#history_kind" do
    it "is :event so the history feed can distinguish it from PlanVersion" do
      expect(build(:plan_event).history_kind).to eq(:event)
    end
  end

  describe "after_initialize" do
    it "defaults metadata to an empty hash (per AGENTS.md JSON-column rule)" do
      expect(CoPlan::PlanEvent.new.metadata).to eq({})
    end
  end

  describe "association with plan" do
    it "is configured to be destroyed when the plan is destroyed" do
      reflection = CoPlan::Plan.reflect_on_association(:plan_events)
      expect(reflection).to be_present
      expect(reflection.options[:dependent]).to eq(:destroy)
    end
  end
end
