require "rails_helper"

RSpec.describe "CommentThreads", type: :request do
  let(:alice) { create(:user, :admin) }
  let(:bob) { create(:user) }
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
    expect(thread.status).to eq("open")
    expect(thread.plan_version_id).to eq(plan.current_plan_version_id)
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
    expect(thread.status).to eq("accepted")
  end

  it "dismiss thread as plan author" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    patch dismiss_plan_comment_thread_path(plan, thread)
    thread.reload
    expect(thread.status).to eq("dismissed")
  end

  it "reopen resolved thread" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    thread.resolve!(alice)
    patch reopen_plan_comment_thread_path(plan, thread)
    thread.reload
    expect(thread.status).to eq("open")
    expect(thread.resolved_by_user_id).to be_nil
  end

  it "non-author cannot accept thread" do
    sign_in_as(bob)
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: bob)
    patch accept_plan_comment_thread_path(plan, thread)
    expect(response).to have_http_status(:not_found)
    thread.reload
    expect(thread.status).to eq("open")
  end
end
