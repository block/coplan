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
    expect(response).to redirect_to(plan_page_path(plan))
    thread = CoPlan::CommentThread.last
    expect(thread.anchor_text).to eq("world domination")
    expect(thread.anchor_start).to be_present # resolved at the door
    expect(thread.status).to eq("open")
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

      expect(response).to redirect_to(plan_page_path(plan))
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
    expect(response).to redirect_to(plan_page_path(plan))
    thread.reload
    expect(thread.status).to eq("resolved")
  end

  it "resolving a thread clears its unread notifications" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: bob)
    notification = create(:notification, user: bob, plan: plan, comment_thread: thread, reason: "agent_response")

    patch resolve_plan_comment_thread_path(plan, thread)

    expect(notification.reload.read_at).to be_present
  end

  it "reopen resolved thread" do
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    thread.resolve!(alice)
    patch reopen_plan_comment_thread_path(plan, thread)
    thread.reload
    expect(thread.status).to eq("open")
    expect(thread.resolved_by_user_id).to be_nil
  end

  it "non-creator, non-plan-author cannot resolve thread" do
    carol = create(:coplan_user)
    sign_in_as(carol)
    thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: bob)
    patch resolve_plan_comment_thread_path(plan, thread)
    expect(response).to have_http_status(:not_found)
    thread.reload
    expect(thread.status).to eq("open")
  end
end

RSpec.describe "Source-backed element comments", type: :request do
  let(:user) { create(:coplan_user) }
  let(:content) { "| A | B |\n|---|---|\n| same | same |\n|||\n" }
  let(:plan) do
    create(:plan, created_by_user: user).tap do |p|
      version = create(:plan_version, plan: p, revision: 2, content_markdown: content)
      p.update!(current_plan_version: version, current_revision: 2)
    end
  end
  let(:targets) do
    html = Commonmarker.to_html(content, options: { render: { sourcepos: true } }, plugins: { syntax_highlighter: nil })
    CoPlan::Plans::SourceTargets.new(content).annotate(Nokogiri::HTML.fragment(html))
      .css("[data-source-target]").map { |cell| JSON.parse(cell["data-source-target"]) }
  end

  before { sign_in_as(user) }

  def post_target(token, body: "Please update this cell")
    post plan_comment_threads_path(plan), params: {
      comment_thread: { source_token: token, anchor_text: "same", anchor_occurrence: 1, body_markdown: body }
    }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
  end

  it "anchors the selected duplicate, ignoring caller-supplied text and occurrence" do
    target = targets[3]
    post_target(target["token"])
    expect(response).to have_http_status(:ok)
    thread = plan.comment_threads.last
    expect(thread).to have_attributes(anchor_start: target["start"], anchor_end: target["end"],
      anchor_text: " same ", anchor_kind: "table_cell", anchor_revision: 2, plan_version: plan.current_plan_version)
    expect(response.body).to include("data-anchor-kind=\"table_cell\"")
    expect(thread.anchor_context_with_highlight).to include("** same **")
  end

  it "creates an empty-cell comment with an editable source fence" do
    post_target(targets.last["token"])
    expect(response).to have_http_status(:ok)
    expect(plan.comment_threads.last).to have_attributes(anchor_text: "||", anchor_kind: "table_cell")
  end

  it "rejects stale source instead of moving onto identical text in another revision" do
    old_token = targets[3]["token"]
    version = create(:plan_version, plan: plan, revision: 3, content_markdown: "prefix\n\n#{content}")
    plan.update!(current_plan_version: version, current_revision: 3)
    expect { post_target(old_token) }.not_to change(CoPlan::CommentThread, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("source-comment-error", "no longer valid")
  end

  it "rejects tampered tokens and rolls back empty comments" do
    expect { post_target(targets.last["token"] + "x") }.not_to change(CoPlan::CommentThread, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect { post_target(targets.last["token"], body: "") }.not_to change(CoPlan::CommentThread, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end
end
