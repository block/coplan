require "rails_helper"

RSpec.describe "CommentThreads", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:bob) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }

  before { sign_in_as(alice) }

  it "create comment thread with anchor text" do
    expect {
      post plan_comment_threads_path(plan), params: {
        comment_thread: {
          anchor_text: "world domination",
          body_markdown: "This needs work."
        }
      }
    }.to change(CoPlan::CommentThread, :count).by(1).and change(CoPlan::Comment, :count).by(1)
    expect(response).to redirect_to(plan_path(plan))
    thread = CoPlan::CommentThread.last
    expect(thread.anchor_text).to eq("world domination")
    expect(thread.status).to eq("todo") # author's own comments start as todo
    expect(thread.plan_version_id).to eq(plan.current_plan_version_id)
  end

  it "broadcasts the popover via requestless partial render, never request-scoped HTML" do
    # The popover contains reply/action forms; request-rendered HTML embeds
    # the actor's session authenticity token, which must not be broadcast.
    expect(CoPlan::Broadcaster).to receive(:append_to) do |_streamable, **kwargs|
      expect(kwargs[:partial]).to eq("coplan/comment_threads/thread_popover")
      expect(kwargs[:html]).to be_nil
    end

    post plan_comment_threads_path(plan), params: {
      comment_thread: { anchor_text: "world domination", body_markdown: "Broadcast safely." }
    }
  end

  it "broadcasts thread status changes via requestless partial render" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    expect(CoPlan::Broadcaster).to receive(:replace_to) do |_streamable, **kwargs|
      expect(kwargs[:partial]).to eq("coplan/comment_threads/thread_popover")
      expect(kwargs[:html]).to be_nil
    end

    patch resolve_plan_comment_thread_path(plan, thread)
  end

  it "create general comment thread" do
    expect {
      post plan_comment_threads_path(plan), params: {
        comment_thread: {
          body_markdown: "General feedback."
        }
      }
    }.to change(CoPlan::CommentThread, :count).by(1)
    thread = CoPlan::CommentThread.last
    expect(thread.anchor_text).to be_nil
  end

  it "resolve thread" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    patch resolve_plan_comment_thread_path(plan, thread)
    expect(response).to redirect_to(plan_path(plan))
    thread.reload
    expect(thread.status).to eq("resolved")
  end

  it "accept thread as plan author" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    patch accept_plan_comment_thread_path(plan, thread)
    thread.reload
    expect(thread.status).to eq("todo")
  end

  it "discard thread as plan author" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    patch discard_plan_comment_thread_path(plan, thread)
    thread.reload
    expect(thread.status).to eq("discarded")
  end

  it "reopen resolved thread" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    thread.resolve!(alice)
    patch reopen_plan_comment_thread_path(plan, thread)
    thread.reload
    expect(thread.status).to eq("pending")
    expect(thread.resolved_by_user_id).to be_nil
  end

  it "non-author cannot accept thread" do
    sign_in_as(bob)
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: bob)
    patch accept_plan_comment_thread_path(plan, thread)
    expect(response).to have_http_status(:not_found)
    thread.reload
    expect(thread.status).to eq("pending")
  end
end
