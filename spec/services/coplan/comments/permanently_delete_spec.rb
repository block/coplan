require "rails_helper"

RSpec.describe CoPlan::Comments::PermanentlyDelete do
  let(:admin) { create(:coplan_user, admin: true) }
  let(:comment) { create(:comment, body_markdown: "Retained original") }
  let(:thread) { comment.comment_thread }
  let(:plan) { thread.plan }

  it "requires an admin and a previously soft-deleted comment" do
    expect { described_class.call(comment: comment, actor: admin) }.to raise_error(described_class::NotAllowed)
    comment.soft_delete!
    expect { described_class.call(comment: comment, actor: create(:coplan_user)) }.to raise_error(described_class::NotAllowed)
    expect(comment.reload.body_markdown).to eq("Retained original")
  end

  it "deletes the retained row and related copies while preserving the thread, replies and audit metadata" do
    reply = create(:comment, comment_thread: thread)
    notification = create(:notification, comment: comment, comment_thread: thread, plan: plan)
    delivery = create(:notification_delivery, notification: notification)
    reaction = create(:comment_reaction, comment: comment)
    event = CoPlan::AgentEvent.create!(api_token: create(:api_token), plan: plan, comment_id: comment.id,
      event_type: "comment.created", payload: { "comment_body" => comment.body_markdown })
    history = CoPlan::PlanEvent.create!(plan: plan, event_type: "comment_deleted", actor_type: "human",
      metadata: { "comment_id" => comment.id, "body_preview" => comment.body_markdown })
    other_history = CoPlan::PlanEvent.create!(plan: plan, event_type: "comment_deleted", actor_type: "human",
      metadata: { "comment_id" => reply.id, "body_preview" => reply.body_markdown })
    comment.soft_delete!

    described_class.call(comment: comment, actor: admin)

    expect(CoPlan::Comment.exists?(comment.id)).to be(false)
    expect(CoPlan::Comment.exists?(reply.id)).to be(true)
    expect(CoPlan::CommentThread.exists?(thread.id)).to be(true)
    expect(CoPlan::Notification.exists?(notification.id)).to be(false)
    expect(CoPlan::NotificationDelivery.exists?(delivery.id)).to be(false)
    expect(CoPlan::CommentReaction.exists?(reaction.id)).to be(false)
    expect(CoPlan::AgentEvent.exists?(event.id)).to be(false)
    expect(history.reload.metadata).to eq("comment_id" => comment.id)
    expect(other_history.reload.metadata["body_preview"]).to eq(reply.body_markdown)
    audit = plan.plan_events.find_by!(event_type: "comment_permanently_deleted")
    expect(audit.actor_user).to eq(admin)
    expect(audit.metadata).to eq("comment_id" => comment.id, "thread_id" => thread.id)
    expect(event.as_api_json[:payload]["comment_body"]).to eq(CoPlan::Comment::DELETED_BODY)
  end

  it "protects immutable review notes while allowing unrelated replies to be purged" do
    request = create(:review_request, plan: plan)
    receipt = create(:review_response, review_request: request, comment_thread: thread, note: comment.body_markdown)
    comment.soft_delete!
    expect { described_class.call(comment: comment, actor: admin) }.to raise_error(described_class::NotAllowed, /immutable review receipt/)
    expect(comment.reload.body_markdown).to eq(receipt.reload.note)

    reply = create(:comment, comment_thread: thread)
    reply.soft_delete!
    described_class.call(comment: reply, actor: admin)
    expect(CoPlan::Comment.exists?(reply.id)).to be(false)
    expect(receipt.reload.note).to eq("Retained original")
  end

  it "rolls back permanent deletion if its broadcast job cannot be queued" do
    comment.soft_delete!
    allow(CoPlan::BroadcastPermanentCommentDeletionJob).to receive(:perform_later).and_return(false)
    expect { described_class.call(comment: comment, actor: admin) }.to raise_error(ActiveJob::EnqueueError)
    expect(comment.reload.body_markdown).to eq("Retained original")
    expect(plan.plan_events.where(event_type: "comment_permanently_deleted")).to be_empty
  end

  it "commits successfully while Cable is unavailable and queues retryable updates" do
    comment.soft_delete!
    admin
    allow(CoPlan::Broadcaster).to receive(:prepend_to).and_raise("Cable unavailable")
    expect { described_class.call(comment: comment, actor: admin) }
      .to have_enqueued_job(CoPlan::BroadcastPermanentCommentDeletionJob)
    expect(CoPlan::Comment.exists?(comment.id)).to be(false)
    expect(CoPlan::Broadcaster).not_to have_received(:prepend_to)
  end
end
