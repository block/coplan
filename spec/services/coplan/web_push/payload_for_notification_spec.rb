require "rails_helper"

RSpec.describe CoPlan::WebPush::PayloadForNotification do
  let(:author)    { create(:coplan_user, name: "Alice") }
  let(:recipient) { create(:coplan_user, name: "Bob") }
  let(:plan)      { create(:plan, title: "My Plan", created_by_user: recipient) }
  let(:thread) do
    create(:comment_thread,
      plan: plan,
      plan_version: plan.current_plan_version,
      created_by_user: author)
  end
  let(:comment) do
    thread.comments.create!(
      author_type: "human",
      author_id: author.id,
      body_markdown: "Looks good — but **what about** [@bob](mention:bob) opinion on this?"
    )
  end

  def notification_for(reason, comment_record: comment)
    create(:notification,
      user: recipient,
      plan: plan,
      comment_thread: thread,
      comment: comment_record,
      reason: reason)
  end

  describe ".call" do
    it "returns title/body/url/tag for a reply" do
      payload = described_class.call(notification_for("reply"))

      expect(payload).to include(
        title: "Alice replied on My Plan",
        tag: "comment-thread-#{thread.id}"
      )
      expect(payload[:url]).to include("/plans/#{plan.id}").and include("thread=#{thread.id}")
    end

    it "uses 'mentioned you' phrasing for mention notifications" do
      payload = described_class.call(notification_for("mention"))

      expect(payload[:title]).to eq("Alice mentioned you on My Plan")
    end

    it "uses 'commented on' phrasing for new_comment notifications" do
      payload = described_class.call(notification_for("new_comment"))

      expect(payload[:title]).to eq("Alice commented on My Plan")
    end

    it "strips mention chips and markdown formatting from the body" do
      payload = described_class.call(notification_for("reply"))

      # Markdown emphasis stripped, mention chip rewritten to @username,
      # whitespace collapsed. Em dash and ordinary punctuation preserved.
      expect(payload[:body]).to eq("Looks good — but what about @bob opinion on this?")
    end

    it "preserves hyphens and # so words like co-worker and URLs survive" do
      hyphen_comment = thread.comments.create!(
        author_type: "human",
        author_id: author.id,
        body_markdown: "My co-worker linked https://example.com/foo-bar#baz"
      )

      payload = described_class.call(notification_for("reply", comment_record: hyphen_comment))

      expect(payload[:body]).to eq("My co-worker linked https://example.com/foo-bar#baz")
    end

    it "truncates long bodies with an ellipsis" do
      long = "x" * 300
      long_comment = thread.comments.create!(
        author_type: "human",
        author_id: author.id,
        body_markdown: long
      )

      payload = described_class.call(notification_for("reply", comment_record: long_comment))

      expect(payload[:body].length).to eq(described_class::BODY_TRUNCATE)
      expect(payload[:body]).to end_with("…")
    end

    it "falls back to 'Someone' when the comment author has no name" do
      anon_comment = thread.comments.create!(
        author_type: "cloud_persona",
        author_id: nil,
        body_markdown: "agent reply"
      )

      payload = described_class.call(notification_for("agent_response", comment_record: anon_comment))

      expect(payload[:title]).to eq("Agent updated a thread on My Plan")
    end
  end
end
