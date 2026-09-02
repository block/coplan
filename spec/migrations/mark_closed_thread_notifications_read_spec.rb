require "rails_helper"
require CoPlan::Engine.root.join("db/migrate/20260819000000_mark_closed_thread_notifications_read.rb")

RSpec.describe MarkClosedThreadNotificationsRead do
  subject(:migration) { described_class.new }

  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }

  # Bypasses the model's current status validation (now just open/resolved)
  # to plant the raw status values this historical migration actually ran
  # against, back when pending/todo/discarded were valid.
  def notification_on(status)
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: user)
    thread.update_column(:status, status)
    create(:notification, user: user, plan: plan, comment_thread: thread)
  end

  before { migration.verbose = false }

  it "marks unread rows on resolved and discarded threads read" do
    resolved = notification_on("resolved")
    discarded = notification_on("discarded")

    migration.up

    expect(resolved.reload.read_at).to be_present
    expect(discarded.reload.read_at).to be_present
  end

  it "leaves rows on open threads unread" do
    pending_row = notification_on("pending")
    todo_row = notification_on("todo")

    migration.up

    expect(pending_row.reload.read_at).to be_nil
    expect(todo_row.reload.read_at).to be_nil
  end

  it "does not rewrite an already-read row" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: user, status: "resolved")
    read_at = 3.days.ago
    already_read = create(:notification, user: user, plan: plan, comment_thread: thread, read_at: read_at)

    migration.up

    expect(already_read.reload.read_at).to be_within(1.second).of(read_at)
  end

  it "is idempotent across repeated runs" do
    row = notification_on("resolved")

    migration.up
    first_pass = row.reload.read_at
    migration.up

    expect(row.reload.read_at).to be_within(1.second).of(first_pass)
  end
end
