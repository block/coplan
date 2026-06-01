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

  # `first_comment_in_thread?` (used by notify_plan_author) compares UUID
  # strings with `id < ?`, which is not insertion-ordered. The analytics
  # path uses a total-count check instead, so a reply whose UUID happens
  # to sort before the existing first comment still records is_first=false.
  it "is not fooled by a reply whose UUID sorts before earlier comments" do
    high_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
    low_id  = "00000000-0000-0000-0000-000000000001"

    create(:comment, comment_thread: thread, body_markdown: "first", id: high_id)

    events = capture_analytics_events do
      thread.comments.create!(
        author_type: "human",
        author_id: user.id,
        body_markdown: "reply",
        id: low_id
      )
    end

    reply_event = events.find { |name, payload| name == "comment_created" && payload[:properties][:comment_id] == low_id }
    expect(reply_event).not_to be_nil
    expect(reply_event.last[:properties][:is_first_in_thread]).to be(false)
  end
end
