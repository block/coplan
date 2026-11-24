require "rails_helper"

RSpec.describe Coplan::CreateNotificationsJob do
  it "skips queued work for a missing or soft-deleted comment" do
    comment = create(:comment)
    thread = comment.comment_thread
    comment.soft_delete!
    expect(Coplan::Notifications::Create).not_to receive(:call)
    described_class.perform_now(comment_thread_id: thread.id, actor_id: thread.created_by_user_id,
      comment_id: comment.id, reason: "new_comment")
    described_class.perform_now(comment_thread_id: thread.id, actor_id: thread.created_by_user_id,
      comment_id: SecureRandom.uuid, reason: "new_comment")
  end

  it "still delivers commentless status events" do
    thread = create(:comment_thread)
    expect(Coplan::Notifications::Create).to receive(:call).with(hash_including(comment_thread: thread, comment: nil, reason: "status_change"))
    described_class.perform_now(comment_thread_id: thread.id, actor_id: thread.created_by_user_id, reason: "status_change")
  end
end
