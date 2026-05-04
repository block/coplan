require "rails_helper"

RSpec.describe CoPlan::Comments::RewriteMentions do
  let!(:hampton) { create(:coplan_user, username: "hampton") }
  let!(:casey) { create(:coplan_user, username: "casey") }

  it "rewrites resolvable @username mentions to canonical markdown" do
    out = described_class.call("Hey @hampton, what about @casey?")
    expect(out).to eq("Hey [@hampton](mention:hampton), what about [@casey](mention:casey)?")
  end

  it "leaves unresolvable @usernames as plain text" do
    out = described_class.call("Hey @nobody and @hampton")
    expect(out).to eq("Hey @nobody and [@hampton](mention:hampton)")
  end

  it "does not match email addresses" do
    out = described_class.call("ping me at hampton@squareup.com")
    expect(out).to eq("ping me at hampton@squareup.com")
  end

  it "does not double-rewrite already-canonical mentions" do
    input = "[@hampton](mention:hampton) is here"
    expect(described_class.call(input)).to eq(input)
  end

  it "rewrites plain mentions in the same body alongside canonical ones" do
    out = described_class.call("[@hampton](mention:hampton) ping @casey too")
    expect(out).to eq("[@hampton](mention:hampton) ping [@casey](mention:casey) too")
  end

  it "does not match @@double-at" do
    out = described_class.call("noise @@hampton")
    expect(out).to eq("noise @@hampton")
  end

  it "handles empty input" do
    expect(described_class.call("")).to eq("")
    expect(described_class.call(nil)).to eq("")
  end

  it "matches at start of string" do
    out = described_class.call("@hampton hi")
    expect(out).to eq("[@hampton](mention:hampton) hi")
  end

  it "preserves trailing punctuation outside the username" do
    out = described_class.call("Calling @hampton.")
    expect(out).to eq("Calling [@hampton](mention:hampton).")
  end
end

RSpec.describe "Comment#rewrite_plain_mentions integration" do
  let!(:hampton) { create(:coplan_user, username: "hampton") }
  let(:author) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:thread) { create(:comment_thread, plan: plan, created_by_user: author) }

  it "rewrites mentions before save" do
    comment = create(:comment,
      comment_thread: thread,
      author_type: "human",
      author_id: author.id,
      body_markdown: "Yo @hampton check this"
    )
    expect(comment.reload.body_markdown).to eq("Yo [@hampton](mention:hampton) check this")
  end

  it "fires a mention notification after the rewrite" do
    expect {
      create(:comment,
        comment_thread: thread,
        author_type: "human",
        author_id: author.id,
        body_markdown: "Plain @hampton mention"
      )
    }.to change(CoPlan::Notification.where(reason: "mention"), :count).by(1)
  end
end
