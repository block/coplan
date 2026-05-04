require "rails_helper"

RSpec.describe CoPlan::Comments::ProcessMentions do
  let(:author) { create(:coplan_user, username: "author", name: "Author Person") }
  let!(:hampton) { create(:coplan_user, username: "hampton", name: "Hampton Catlin") }
  let!(:casey) { create(:coplan_user, username: "casey", name: "Casey Reviewer") }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:thread) { create(:comment_thread, plan: plan, created_by_user: author) }

  def make_comment(body, by: author)
    create(:comment, comment_thread: thread, author_type: "human", author_id: by.id, body_markdown: body)
  end

  it "creates a notification for each resolved mention" do
    expect {
      make_comment("Hey [@hampton](mention:hampton) and [@casey](mention:casey), what do you think?")
    }.to change(CoPlan::Notification, :count).by(2)

    notifications = CoPlan::Notification.where(reason: "mention")
    expect(notifications.pluck(:user_id)).to match_array([hampton.id, casey.id])
    expect(notifications.pluck(:plan_id).uniq).to eq([plan.id])
    expect(notifications.pluck(:comment_thread_id).uniq).to eq([thread.id])
  end

  it "does not notify the author when they @-mention themselves" do
    expect {
      make_comment("Note to self: [@author](mention:author) follow up", by: author)
    }.not_to change(CoPlan::Notification.where(reason: "mention"), :count)
  end

  it "does not notify for usernames that don't resolve to a user" do
    expect {
      make_comment("Hey [@notreal](mention:notreal) what do you think?")
    }.not_to change(CoPlan::Notification.where(reason: "mention"), :count)
  end

  it "ignores email-like @-text that isn't a real mention" do
    expect {
      make_comment("Reach me at hampton@squareup.com")
    }.not_to change(CoPlan::Notification.where(reason: "mention"), :count)
  end

  it "deduplicates when the same user is mentioned multiple times" do
    expect {
      make_comment("[@hampton](mention:hampton) [@hampton](mention:hampton) [@hampton](mention:hampton)")
    }.to change(CoPlan::Notification.where(reason: "mention"), :count).by(1)
  end

  it "ignores `[foo](mention:bar)` where text and target don't match" do
    expect {
      make_comment("[hello](mention:hampton) is not a mention")
    }.not_to change(CoPlan::Notification.where(reason: "mention"), :count)
  end
end
