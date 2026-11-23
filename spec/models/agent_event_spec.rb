require "rails_helper"

RSpec.describe Coplan::AgentEvent do
  it "redacts a batch using one comment-state query while retaining stored bodies" do
    token = create(:api_token)
    plan = create(:plan)
    thread = create(:comment_thread, plan: plan)
    comments = Array.new(10) { create(:comment, comment_thread: thread, body_markdown: "Stored body") }
    events = comments.map do |comment|
      described_class.create!(api_token: token, plan: plan, comment_id: comment.id,
        event_type: "comment.created", payload: { "comment_body" => comment.body_markdown })
    end
    comments.first.soft_delete!

    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql].match?(/SELECT.*FROM [`"]?coplan_comments/i)
    end
    batch = described_class.uncached { described_class.as_api_json_batch(events) }
    expect(queries.size).to eq(1)
    expect(batch.first[:payload]["comment_body"]).to eq(Coplan::Comment::DELETED_BODY)
    expect(batch.drop(1).map { |item| item[:payload]["comment_body"] }).to all(eq("Stored body"))
    expect(events.first.reload.payload["comment_body"]).to eq("Stored body")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
