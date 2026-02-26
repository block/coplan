require "rails_helper"

RSpec.describe CoPlan::CommentThread, type: :model do
  let(:org) { create(:organization) }
  let(:user) { create(:user, organization: org) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:thread_record) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: user) }

  it "is valid with valid attributes" do
    expect(thread_record).to be_valid
  end

  it "validates status inclusion" do
    thread_record.status = "invalid"
    expect(thread_record).not_to be_valid
    expect(thread_record.errors[:status]).to include("is not included in the list")
  end

  it "returns true for line_specific? when lines set" do
    thread_record.start_line = 5
    thread_record.end_line = 8
    expect(thread_record).to be_line_specific
  end

  it "returns false for line_specific? for general thread" do
    expect(thread_record).not_to be_line_specific
  end

  it "returns line range text for range" do
    thread_record.start_line = 5
    thread_record.end_line = 8
    expect(thread_record.line_range_text).to eq("Lines 5–8")
  end

  it "returns line text for single line" do
    thread_record.start_line = 5
    thread_record.end_line = 5
    expect(thread_record.line_range_text).to eq("Line 5")
  end

  it "returns nil line_range_text for general thread" do
    expect(thread_record.line_range_text).to be_nil
  end

  it "resolve! sets status and user" do
    thread_record.resolve!(user)
    expect(thread_record.status).to eq("resolved")
    expect(thread_record.resolved_by_user).to eq(user)
  end

  it "accept! sets status and user" do
    thread_record.accept!(user)
    expect(thread_record.status).to eq("accepted")
    expect(thread_record.resolved_by_user).to eq(user)
  end

  it "dismiss! sets status and user" do
    thread_record.dismiss!(user)
    expect(thread_record.status).to eq("dismissed")
    expect(thread_record.resolved_by_user).to eq(user)
  end

  it "open_threads scope returns only open threads" do
    open_threads = plan.comment_threads.open_threads
    expect(open_threads).to all(have_attributes(status: "open"))
  end

  it "returns true for anchored? when anchor_text set" do
    thread_record.anchor_text = "some text"
    expect(thread_record).to be_anchored
  end

  it "returns false for anchored? when anchor_text blank" do
    expect(thread_record).not_to be_anchored
  end

  it "truncates long anchor text in anchor_preview" do
    thread_record.anchor_text = "a" * 100
    expect(thread_record.anchor_preview).to eq("a" * 80 + "…")
  end

  it "returns short anchor text as-is in anchor_preview" do
    thread_record.anchor_text = "short text"
    expect(thread_record.anchor_preview).to eq("short text")
  end

  describe ".active scope" do
    it "returns open non-out-of-date threads" do
      thread_record # ensure it exists
      active = plan.comment_threads.active
      expect(active).to all(have_attributes(status: "open", out_of_date: false))
    end

    it "excludes resolved threads" do
      thread_record.resolve!(user)
      active = plan.comment_threads.active
      expect(active).not_to include(thread_record)
    end

    it "excludes out-of-date threads" do
      thread_record.update_columns(out_of_date: true)
      active = plan.comment_threads.active
      expect(active).not_to include(thread_record)
    end
  end

  describe ".archived scope" do
    it "returns non-open or out-of-date threads" do
      archived = plan.comment_threads.archived
      expect(archived).to all(satisfy { |t| t.status != "open" || t.out_of_date? })
    end

    it "includes resolved threads" do
      thread_record.resolve!(user)
      archived = plan.comment_threads.archived
      expect(archived).to include(thread_record)
    end
  end

  describe ".mark_out_of_date_for_new_version!" do
    it "marks out-of-date when thread lacks positional data" do
      thread_record.update_columns(anchor_text: "world domination")

      new_version = CoPlan::PlanVersion.create!(
        plan: plan,
        revision: plan.current_revision + 1,
        content_markdown: "# Plan\n\nOur plan for world domination continues.",
        actor_type: "human",
        actor_id: user.id
      )

      plan.comment_threads.mark_out_of_date_for_new_version!(new_version)
      thread_record.reload
      expect(thread_record).to be_out_of_date
    end

    it "skips non-anchored threads" do
      new_version = CoPlan::PlanVersion.create!(
        plan: plan,
        revision: plan.current_revision + 1,
        content_markdown: "Completely different content.",
        actor_type: "human",
        actor_id: user.id
      )

      plan.comment_threads.mark_out_of_date_for_new_version!(new_version)
      thread_record.reload
      expect(thread_record).not_to be_out_of_date
    end

    it "ignores non-positive anchor_occurrence values" do
      thread_record.update_columns(anchor_text: "plan")
      thread_record.anchor_occurrence = 0

      thread_record.send(:resolve_anchor_position)
      expect(thread_record.anchor_start).to be_nil
    end
  end
end
