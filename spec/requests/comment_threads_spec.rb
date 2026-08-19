require "rails_helper"

RSpec.describe "CommentThreads", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:bob) { create(:coplan_user) }

  # Threads refuse anchors that don't resolve, so the plan has to actually
  # say the thing these specs anchor to.
  let(:plan) do
    create(:plan, :considering, created_by_user: alice).tap do |p|
      version = create(:plan_version, plan: p, revision: 2, actor_id: alice.id,
        content_markdown: "## Ambition\n\nOur goal is world domination by Q3.\n")
      p.update_columns(current_plan_version_id: version.id, current_revision: 2)
    end
  end

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
    expect(thread.anchor_start).to be_present # resolved at the door
    expect(thread.status).to eq("todo") # author's own comments start as todo
    expect(thread.plan_version_id).to eq(plan.current_plan_version_id)
  end

  # A thread whose anchor never resolved renders nowhere — no highlight, no
  # popover, no way to reach it. "Comment posted" followed by nothing
  # visible is worse than a refusal.
  describe "when the anchor doesn't resolve against the plan" do
    it "refuses to create the thread" do
      expect {
        post plan_comment_threads_path(plan), params: {
          comment_thread: { anchor_text: "text the plan never says", body_markdown: "Lost forever." }
        }
      }.not_to change { [ CoPlan::CommentThread.count, CoPlan::Comment.count ] }

      expect(response).to redirect_to(plan_path(plan))
      expect(flash[:alert]).to include("nowhere to appear")
    end

    it "tells a turbo-stream client with a 422 so it can fall back" do
      post plan_comment_threads_path(plan),
        params: { comment_thread: { anchor_text: "text the plan never says", body_markdown: "Lost." } },
        headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("new-comment-form-error")
      expect(response.body).to include("nowhere to appear")
    end
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

  it "resolving a thread clears its unread notifications" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: bob)
    notification = create(:notification, user: bob, plan: plan, comment_thread: thread, reason: "agent_response")

    patch resolve_plan_comment_thread_path(plan, thread)

    expect(notification.reload.read_at).to be_present
  end

  it "discarding a thread clears its unread notifications" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: bob)
    notification = create(:notification, user: bob, plan: plan, comment_thread: thread)

    patch discard_plan_comment_thread_path(plan, thread)

    expect(notification.reload.read_at).to be_present
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
