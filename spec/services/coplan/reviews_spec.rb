require "rails_helper"

RSpec.describe "CoPlan reviews" do
  include ActiveJob::TestHelper

  let(:plan) { create(:plan, :published) }
  let(:reviewer) { create(:coplan_user) }
  let(:request) { create(:review_request, plan: plan, reviewer: reviewer) }

  def respond(decision: "approved", note: nil, **attributes)
    CoPlan::Reviews::Respond.call(request: request, actor: reviewer, revision: plan.current_revision,
      decision: decision, note: note, **attributes)
  end

  it "requests optional review and sends a notification without granting permissions" do
    task = CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user, requirement: "optional")
    expect(task.requirement).to eq("optional")
    expect(task.notifications.last).to have_attributes(user_id: reviewer.id, reason: "review_requested", comment_thread_id: nil)
    expect(CoPlan::PlanPolicy.new(reviewer, plan).update?).to be(false)
    expect(plan.plan_collaborators).to be_empty
  end

  it "preserves the original approval after edits and another review request" do
    response = respond(note: "Looks right")
    expect(response.comment_thread.comments.first.body_markdown).to eq("Looks right")
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "A revised plan")
    plan.update!(current_plan_version: version, current_revision: 2)
    expect(request.reload.status).to eq("approved")
    expect(response.reload.plan_version.revision).to eq(1)
    CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: plan.created_by_user)
    expect(request.reload).to be_pending
    expect(request.latest_approval.id).to eq(response.id)
    expect(request.requested_plan_version).to eq(version)
  end

  it "keeps pending requests on the latest plan and binds only the completed response" do
    task = request
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "Latest plan")
    plan.update!(current_plan_version: version, current_revision: 2)
    expect(CoPlan::Reviews::Serialize.call(task)).not_to have_key(:requested_revision)
    response = respond
    expect(response.plan_version).to eq(version)
    expect(CoPlan::Reviews::Serialize.call(task.reload)[:responses].first[:revision]).to eq(2)
  end

  it "creates a public ordinary comment thread for requested changes and notifies the author" do
    response = respond(decision: "changes_requested", note: "Please explain retries")
    expect(response.comment_thread).to have_attributes(plan_id: plan.id, plan_version_id: plan.current_plan_version_id, status: "open")
    expect(response.comment_thread.comments.last).to have_attributes(author_type: "human", author_id: reviewer.id, body_markdown: "Please explain retries")
    expect(request.reload.status).to eq("changes_requested")
    expect(plan.notifications.where(user: plan.created_by_user, reason: "review_response")).to exist
  end

  %w[approved changes_requested].each do |decision|
    it "notifies the author once for #{decision} notes while preserving comment subscribers and agent events" do
      co_author = create(:coplan_user)
      create(:plan_collaborator, plan: plan, user: co_author, role: "author")
      token = create(:api_token, user: plan.created_by_user)
      CoPlan::AgentSession.create!(plan: plan, api_token: token, state: "watching", agent_name: "Authorbot")

      response = nil
      perform_enqueued_jobs(only: CoPlan::CreateNotificationsJob) do
        response = respond(decision: decision, note: "Please verify retries")
      end

      notifications = plan.notifications.where(comment_thread: response.comment_thread)
      expect(notifications.where(user: plan.created_by_user).pluck(:reason)).to eq([ "review_response" ])
      expect(notifications.where(user: co_author).pluck(:reason)).to eq([ "new_comment" ])
      expect(notifications.where(user: reviewer)).to be_empty
      expect(CoPlan::AgentEvent.pluck(:event_type)).to contain_exactly("comment.created", "review.responded")

      reply = response.comment_thread.comments.create!(body_markdown: "Updated the example", author_type: "human", author_id: co_author.id)
      CoPlan::CreateNotificationsJob.perform_now(comment_thread_id: response.comment_thread.id,
        actor_id: co_author.id, comment_id: reply.id, reason: "reply")
      expect(notifications.where(user: plan.created_by_user).pluck(:reason)).to contain_exactly("review_response", "reply")
      expect(notifications.where(user: reviewer).pluck(:reason)).to eq([ "reply" ])
    end
  end

  it "rejects empty changes, stale responses and withdrawn requests without leaving orphan comments" do
    request
    expect { respond(decision: "changes_requested", note: " ") }.to raise_error(ActiveRecord::RecordInvalid)
    expect(plan.comment_threads).to be_empty
    expect { CoPlan::Reviews::Respond.call(request: request, actor: reviewer, revision: 0, decision: "approved") }.to raise_error(CoPlan::Reviews::Respond::Conflict)
    request.update!(status: "withdrawn")
    expect { respond }.to raise_error(CoPlan::Reviews::Respond::Conflict)
    expect(request.review_responses).to be_empty
  end

  it "does not duplicate sign-offs on a retry" do
    first = respond(note: "Reviewed")
    expect { expect(respond(note: "Reviewed").id).to eq(first.id) }.not_to change(CoPlan::ReviewResponse, :count)
  end

  it "attributes agent decisions explicitly to the agent and human principal" do
    token = create(:api_token, user: reviewer, agent_name: "Reviewbot")
    response = respond(api_token: token)
    expect(response).to have_attributes(actor_type: "local_agent", agent_name: "Reviewbot", user_id: reviewer.id, api_token_id: token.id)
  end

  it "bounds attribution from older tokens with long display names" do
    token = create(:api_token, user: reviewer, name: "A legacy token with a long display name", agent_name: nil)
    response = respond(api_token: token)
    expect(response.agent_name.length).to be <= CoPlan::ApiToken::AGENT_NAME_LIMIT
  end

  it "publishes responses to attached agents with the narrow approval meaning" do
    token = create(:api_token, user: plan.created_by_user)
    CoPlan::AgentSession.create!(plan: plan, api_token: token, state: "watching", agent_name: "Authorbot")
    respond
    event = CoPlan::AgentEvent.where(event_type: "review.responded").last
    expect(event.payload).to include("revision" => 1, "approval_meaning" => "Satisfied with this version; grants no execution authority or permissions.")
  end

  it "can cascade a deleted request's immutable history" do
    respond
    expect { request.destroy! }.not_to raise_error
    expect(CoPlan::ReviewResponse.where(review_request_id: request.id)).to be_empty
  end
end
