require "rails_helper"

RSpec.describe "Api::V1::ReviewRequests", type: :request do
  let(:author) { create(:coplan_user) }
  let(:reviewer) { create(:coplan_user) }
  let(:plan) { create(:plan, :published, created_by_user: author) }
  let(:task) { create(:review_request, plan: plan, reviewer: reviewer) }
  let(:author_token) { create(:api_token, user: author, raw_token: "reviews-owner", agent_name: "Authorbot") }
  let(:reviewer_token) { create(:api_token, user: reviewer, raw_token: "reviews-reviewer", agent_name: "Reviewbot") }

  def headers(token)
    { "Authorization" => "Bearer #{token}" }
  end

  before { author_token; reviewer_token }

  it "preserves the author's unread response when withdrawing a review" do
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: plan.current_revision, decision: "approved")
    response_notice = author.notifications.find_by!(review_request: task, reason: "review_response")
    request_notice = CoPlan::Notification.create!(user: reviewer, plan: plan, review_request: task, reason: "review_requested")
    watcher = reviewer_token
    CoPlan::AgentSession.create!(plan: plan, api_token: watcher, state: "watching", agent_name: "Watcher")
    delete api_v1_plan_review_request_path(plan, task), headers: headers("reviews-owner")
    expect(response).to have_http_status(:no_content)
    expect(task.reload.status).to eq("withdrawn")
    expect(request_notice.reload).to be_read
    expect(response_notice.reload).not_to be_read
    expect(watcher.agent_events.last!.payload).to include("action" => "withdrawn", "withdrawn" => true)
    expect(task.review_responses.count).to eq(1)
  end

  it "distinguishes requirement updates from new requests in live events" do
    CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: plan.current_revision, decision: "approved")
    requested_at = task.requested_at
    watcher = reviewer_token
    CoPlan::AgentSession.create!(plan: plan, api_token: watcher, state: "watching", agent_name: "Watcher")
    patch api_v1_plan_review_request_path(plan, task), params: { requirement: "optional" }, headers: headers("reviews-owner"), as: :json
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(requirement: "optional", status: "approved", requested_at: requested_at)
    event = watcher.agent_events.last!
    expect(event.event_type).to eq("review.requested")
    expect(event.payload).to include("action" => "requirement_changed", "requirement" => "optional", "review_request_id" => task.id)
    expect(task.review_responses.count).to eq(1)
  end

  it "allows delegated author assignment and lists immutable response history in snapshots" do
    post api_v1_plan_review_requests_path(plan), params: { reviewer_id: reviewer.id, requirement: "optional" }, headers: headers("reviews-owner"), as: :json
    expect(response).to have_http_status(:created)
    request = plan.review_requests.last
    post respond_api_v1_plan_review_request_path(plan, request), params: { revision: 1, decision: "approved", note: "Reviewed by agent" }, headers: headers("reviews-reviewer"), as: :json
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)).to include("actor_type" => "local_agent", "agent_name" => "Reviewbot")
    get snapshot_api_v1_plan_path(plan), headers: headers("reviews-owner")
    history = JSON.parse(response.body).fetch("review_requests").first.fetch("responses").first
    expect(history).to include("revision" => 1, "agent_name" => "Reviewbot", "note" => "Reviewed by agent")
  end

  it "refuses management by a reviewer and refuses impersonating the assigned reviewer" do
    post api_v1_plan_review_requests_path(plan), params: { reviewer_id: author.id }, headers: headers("reviews-reviewer"), as: :json
    expect(response).to have_http_status(:forbidden)
    post respond_api_v1_plan_review_request_path(plan, task), params: { revision: 1, decision: "approved" }, headers: headers("reviews-owner"), as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "supports public change requests, requirement updates, re-requests and withdrawal" do
    post respond_api_v1_plan_review_request_path(plan, task), params: { revision: 1, decision: "changes_requested", note: "Clarify this contract" }, headers: headers("reviews-reviewer"), as: :json
    expect(response).to have_http_status(:created)
    expect(task.review_responses.last.comment_thread.comments.last.agent_name).to eq("Reviewbot")
    patch api_v1_plan_review_request_path(plan, task), params: { requirement: "optional" }, headers: headers("reviews-owner"), as: :json
    expect(response).to have_http_status(:ok)
    patch api_v1_plan_review_request_path(plan, task), params: { request_again: true }, headers: headers("reviews-owner"), as: :json
    expect(response).to have_http_status(:ok)
    expect(task.reload).to be_pending
    get api_v1_plan_review_requests_path(plan), headers: headers("reviews-owner")
    expect(JSON.parse(response.body).fetch("review_requests").first.fetch("responses").size).to eq(1)
    delete api_v1_plan_review_request_path(plan, task), headers: headers("reviews-owner")
    expect(response).to have_http_status(:no_content)
  end

  it "replays a keyed API response without completing a new request for the same version" do
    key = SecureRandom.uuid
    payload = { revision: plan.current_revision, decision: "approved", note: "Reviewed", idempotency_key: key }
    post respond_api_v1_plan_review_request_path(plan, task), params: payload, headers: headers("reviews-reviewer"), as: :json
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body).fetch("id")).to eq(key)
    patch api_v1_plan_review_request_path(plan, task), params: { request_again: true }, headers: headers("reviews-owner"), as: :json
    post respond_api_v1_plan_review_request_path(plan, task), params: payload, headers: headers("reviews-reviewer"), as: :json
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body).fetch("id")).to eq(key)
    expect(task.reload.status).to eq("pending")
    expect(task.review_responses.count).to eq(1)
    post respond_api_v1_plan_review_request_path(plan, task), params: payload.merge(idempotency_key: SecureRandom.uuid), headers: headers("reviews-reviewer"), as: :json
    expect(response).to have_http_status(:created)
    expect(task.reload.status).to eq("approved")
    expect(task.review_responses.count).to eq(2)
  end

  it "distinguishes a withdrawn task from a stale revision without recording a response" do
    task.update!(status: "withdrawn")
    post respond_api_v1_plan_review_request_path(plan, task),
      params: { revision: plan.current_revision, decision: "approved", note: "Must not create feedback" },
      headers: headers("reviews-reviewer"), as: :json
    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body).fetch("code")).to eq("review_request_withdrawn")
    expect(task.reload.status).to eq("withdrawn")
    expect(task.review_responses).to be_empty
    expect(plan.comment_threads).to be_empty
  end

  it "requires a token, rejects stale revisions and returns useful validation errors" do
    get api_v1_plan_review_requests_path(plan)
    expect(response).to have_http_status(:unauthorized)
    post respond_api_v1_plan_review_request_path(plan, task), params: { revision: 0, decision: "approved" }, headers: headers("reviews-reviewer"), as: :json
    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body).fetch("code")).to eq("review_version_changed")
    post api_v1_plan_review_requests_path(plan), params: { reviewer_id: reviewer.id, requirement: "all" }, headers: headers("reviews-owner"), as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end
end
