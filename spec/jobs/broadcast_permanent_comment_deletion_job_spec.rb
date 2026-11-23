require "rails_helper"

RSpec.describe CoPlan::BroadcastPermanentCommentDeletionJob do
  let(:thread) { create(:comment_thread) }
  let(:event) do
    CoPlan::PlanEvent.create!(plan: thread.plan, event_type: "comment_permanently_deleted", actor_type: "human",
      metadata: { "comment_id" => SecureRandom.uuid, "thread_id" => thread.id })
  end

  it "retries broadcast failures independently of the completed deletion" do
    event
    allow(CoPlan::Broadcaster).to receive(:prepend_to).and_raise("Cable unavailable")
    expect { described_class.perform_now(event_id: event.id, user_ids: []) }.to have_enqueued_job(described_class)

    allow(CoPlan::Broadcaster).to receive(:prepend_to)
    expect(CoPlan::Broadcaster).to receive(:remove_to).with(thread.plan, target: ActionView::RecordIdentifier.dom_id(thread))
    expect(CoPlan::Notifications::BroadcastBadges).to receive(:call).with(user_ids: [])
    described_class.perform_now(event_id: event.id, user_ids: [])
  end

  it "retries when a separate queue worker reaches an uncommitted audit event" do
    expect { described_class.perform_now(event_id: SecureRandom.uuid, user_ids: []) }.to have_enqueued_job(described_class)
  end
end
