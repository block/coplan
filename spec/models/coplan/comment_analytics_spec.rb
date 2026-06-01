require "rails_helper"

RSpec.describe CoPlan::Comment, "analytics" do
  let(:user) { create(:coplan_user) }
  let(:thread) { create(:comment_thread, created_by_user: user) }

  it "tracks a comment_created event when a comment is created" do
    events = capture_analytics_events do
      thread.comments.create!(
        author_type: "human",
        author_id: user.id,
        body_markdown: "first comment"
      )
    end

    comment_events = events.select { |name, _| name == "comment_created" }
    expect(comment_events.length).to eq(1)

    _, payload = comment_events.first
    expect(payload[:user_id]).to eq(user.id)
    expect(payload[:properties]).to include(
      plan_id: thread.plan_id,
      comment_thread_id: thread.id,
      author_type: "human",
      is_first_in_thread: true,
      body_length: "first comment".length
    )
    expect(payload[:properties][:comment_id]).to be_present
  end

  it "marks subsequent comments as not the first in thread" do
    create(:comment, comment_thread: thread, body_markdown: "first")

    events = capture_analytics_events do
      thread.comments.create!(
        author_type: "human",
        author_id: user.id,
        body_markdown: "second"
      )
    end

    _, payload = events.find { |name, _| name == "comment_created" }
    expect(payload[:properties][:is_first_in_thread]).to be(false)
  end
end
