require "rails_helper"

RSpec.describe CoPlan::Notifications::NeedsAttention do
  let(:user) { create(:coplan_user) }
  let(:other_user) { create(:coplan_user) }

  def notify(plan, count: 1, user: self.user, read: false)
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: other_user)
    count.times do
      create(:notification, user: user, plan: plan, comment_thread: thread, read_at: read ? Time.current : nil)
    end
  end

  it "counts unread rows per plan and orders plans most-unread first" do
    quiet = create(:plan, :considering, created_by_user: user, title: "Quiet")
    loud = create(:plan, :considering, created_by_user: user, title: "Loud")
    notify(quiet, count: 1)
    notify(loud, count: 3)

    result = described_class.call(user: user)

    expect(result.plans.map(&:title)).to eq([ "Loud", "Quiet" ])
    expect(result.unread_count_for(loud)).to eq(3)
    expect(result.unread_count_for(quiet)).to eq(1)
    expect(result).to be_any
  end

  it "ignores read rows and other people's rows" do
    plan = create(:plan, :considering, created_by_user: user)
    notify(plan, read: true)
    notify(plan, user: other_user)

    result = described_class.call(user: user)

    expect(result.plans).to be_empty
    expect(result).not_to be_any
    expect(result.unread_counts).to be_empty
  end

  it "points each row at an unread notification for that plan" do
    plan = create(:plan, :considering, created_by_user: user)
    notify(plan)

    result = described_class.call(user: user)

    notification = user.notifications.unread.first
    expect(result.notification_id_for(plan)).to eq(notification.id)
  end

  it "caps the strip at LIMIT plans and reports the remainder" do
    plans = Array.new(described_class::LIMIT + 2) { |i| create(:plan, :considering, created_by_user: user, title: "Plan #{i}") }
    plans.each_with_index { |plan, i| notify(plan, count: i + 1) }

    result = described_class.call(user: user)

    expect(result.plans.size).to eq(described_class::LIMIT)
    expect(result.remaining).to eq(2)
  end

  it "drops a plan whose rows were cleared between the count and the lookup" do
    plan = create(:plan, :considering, created_by_user: user)
    notify(plan)
    # Simulates another tab clearing the plan mid-request: the grouped
    # count still sees the row, the per-plan lookup no longer does.
    allow_any_instance_of(ActiveRecord::Relation).to receive(:pick).and_return(nil)

    result = described_class.call(user: user)

    expect(result.plans).to be_empty
  end

  it "never surfaces a plan the viewer cannot see" do
    hidden = create(:plan, :draft, created_by_user: other_user)
    notify(hidden)

    result = described_class.call(user: user)

    expect(result.plans).to be_empty
  end
end
