require "rails_helper"

RSpec.describe CoPlan::Notifications::MarkPlanRead do
  let(:author) { create(:coplan_user) }
  let(:reviewer) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:thread) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: reviewer) }

  before { allow(CoPlan::Broadcaster).to receive(:update_to) }

  it "marks every unread row this person carries for the plan read" do
    first = create(:notification, user: author, plan: plan, comment_thread: thread)
    second = create(:notification, user: author, plan: plan, comment_thread: thread, reason: "agent_response")

    expect(described_class.call(user: author, plan_id: plan.id)).to eq(2)
    expect(first.reload.read_at).to be_present
    expect(second.reload.read_at).to be_present
  end

  it "leaves rows for other plans alone" do
    other_plan = create(:plan, created_by_user: author)
    other_thread = create(:comment_thread, plan: other_plan, plan_version: other_plan.current_plan_version, created_by_user: reviewer)
    other = create(:notification, user: author, plan: other_plan, comment_thread: other_thread)

    described_class.call(user: author, plan_id: plan.id)

    expect(other.reload.read_at).to be_nil
  end

  it "leaves other people's rows for the same plan alone" do
    theirs = create(:notification, user: reviewer, plan: plan, comment_thread: thread)

    described_class.call(user: author, plan_id: plan.id)

    expect(theirs.reload.read_at).to be_nil
  end

  it "does not rewrite an already-read row's timestamp" do
    read_at = 2.days.ago
    already_read = create(:notification, user: author, plan: plan, comment_thread: thread, read_at: read_at)

    described_class.call(user: author, plan_id: plan.id)

    expect(already_read.reload.read_at).to be_within(1.second).of(read_at)
  end

  it "refreshes the badge" do
    create(:notification, user: author, plan: plan, comment_thread: thread)

    expect(CoPlan::Broadcaster).to receive(:update_to).with(
      "coplan_notifications:#{author.id}",
      target: "inbox-badge",
      html: "0"
    )

    described_class.call(user: author, plan_id: plan.id)
  end

  # Every plan view calls this, and almost every view has nothing to clear.
  it "broadcasts nothing when there was nothing unread" do
    expect(CoPlan::Broadcaster).not_to receive(:update_to)
    expect(described_class.call(user: author, plan_id: plan.id)).to eq(0)
  end

  it "does nothing without a plan id" do
    unrelated = create(:notification, user: author, plan: plan, comment_thread: thread)

    expect(described_class.call(user: author, plan_id: "")).to eq(0)
    expect(unrelated.reload.read_at).to be_nil
  end
end
