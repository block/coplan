require "rails_helper"

RSpec.describe CoPlan::CommentThread, "analytics" do
  let(:user) { create(:coplan_user) }
  let(:thread) { create(:comment_thread) }

  it "tracks a thread_resolved event when resolve! is called" do
    create(:comment, comment_thread: thread)
    create(:comment, comment_thread: thread)

    events = capture_analytics_events { thread.resolve!(user) }

    expect(events.length).to eq(1)
    event_name, payload = events.first
    expect(event_name).to eq("thread_resolved")
    expect(payload[:user_id]).to eq(user.id)
    expect(payload[:properties]).to include(
      plan_id: thread.plan_id,
      comment_thread_id: thread.id,
      previous_status: "open",
      comment_count: 2,
      anchored: false
    )
  end
end
