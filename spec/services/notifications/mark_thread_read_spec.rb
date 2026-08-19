require "rails_helper"

RSpec.describe CoPlan::Notifications::MarkThreadRead do
  let(:author) { create(:coplan_user) }
  let(:reviewer) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:thread) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: reviewer) }

  before { allow(CoPlan::Broadcaster).to receive(:update_to) }

  it "marks every unread row for the thread read" do
    first = create(:notification, user: author, plan: plan, comment_thread: thread)
    second = create(:notification, user: reviewer, plan: plan, comment_thread: thread, reason: "agent_response")

    expect(described_class.call(comment_thread: thread)).to eq(2)
    expect(first.reload.read_at).to be_present
    expect(second.reload.read_at).to be_present
  end

  it "leaves rows for other threads alone" do
    other_thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: reviewer)
    other = create(:notification, user: author, plan: plan, comment_thread: other_thread)

    described_class.call(comment_thread: thread)

    expect(other.reload.read_at).to be_nil
  end

  it "does not rewrite an already-read row's timestamp" do
    read_at = 2.days.ago
    already_read = create(:notification, user: author, plan: plan, comment_thread: thread, read_at: read_at)

    described_class.call(comment_thread: thread)

    expect(already_read.reload.read_at).to be_within(1.second).of(read_at)
  end

  it "refreshes the badge for each affected person" do
    create(:notification, user: author, plan: plan, comment_thread: thread)

    expect(CoPlan::Broadcaster).to receive(:update_to).with(
      "coplan_notifications:#{author.id}",
      target: "inbox-badge",
      html: "0"
    )

    described_class.call(comment_thread: thread)
  end

  it "broadcasts nothing when there was nothing unread" do
    expect(CoPlan::Broadcaster).not_to receive(:update_to)
    expect(described_class.call(comment_thread: thread)).to eq(0)
  end
end
