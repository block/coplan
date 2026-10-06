require "rails_helper"

RSpec.describe "Review requests", type: :request do
  let(:author) { create(:coplan_user, email: "review-owner@test.example.com") }
  let(:reviewer) { create(:coplan_user, email: "reviewer@test.example.com") }
  let(:plan) { create(:plan, :published, created_by_user: author) }
  let(:task) { create(:review_request, plan: plan, reviewer: reviewer) }

  it "lets the author assign, make optional, request again and withdraw" do
    sign_in_as(author)
    post plan_review_requests_path(plan), params: { review_request: { reviewer_id: reviewer.id, requirement: "required" } }, as: :json
    expect(response).to have_http_status(:created)
    request = plan.review_requests.last
    patch plan_review_request_path(plan, request), params: { review_request: { requirement: "optional" } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(request.reload.requirement).to eq("optional")
    patch plan_review_request_path(plan, request), params: { review_request: { request_again: true } }, as: :json
    expect(response).to have_http_status(:ok)
    delete plan_review_request_path(plan, request), as: :json
    expect(response).to have_http_status(:no_content)
    expect(request.reload.status).to eq("withdrawn")
  end

  it "allows only the assigned person to respond and only the author to manage" do
    sign_in_as(reviewer)
    post plan_review_requests_path(plan), params: { review_request: { reviewer_id: author.id } }, as: :json
    expect(response).to have_http_status(:not_found)
    sign_in_as(author)
    post respond_plan_review_request_path(plan, task), params: { review_response: { revision: 1, decision: "approved" } }, as: :json
    expect(response).to have_http_status(:not_found)
    sign_in_as(reviewer)
    post respond_plan_review_request_path(plan, task), params: { review_response: { revision: 1, decision: "approved", note: "Satisfied" } }, as: :json
    expect(response).to have_http_status(:created)
  end

  it "reports stale review conflicts and invalid comments" do
    sign_in_as(reviewer)
    post respond_plan_review_request_path(plan, task), params: { review_response: { revision: 0, decision: "approved" } }, as: :json
    expect(response).to have_http_status(:conflict)
    post respond_plan_review_request_path(plan, task), params: { review_response: { revision: 1, decision: "changes_requested", note: " " } }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "keeps an assigned review in the inbox after the notification and plan are read" do
    CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: author)
    sign_in_as(reviewer)
    post mark_all_read_notifications_path, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    get CoPlan::Urls::Canonical.plan_path(plan)
    expect(response).to have_http_status(:ok)
    get notifications_path(panel: 1)
    expect(response.body).to include("Reviews requested", "Review pending", plan.title)
  end

  it "compares the approved revision directly with the current version, escaping content" do
    approval = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, decision: "approved")
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: "New <script>alert(1)</script> content")
    plan.update!(current_plan_version: version, current_revision: 2)
    sign_in_as(reviewer)
    get compare_plan_review_request_path(plan, task, response_id: approval.id)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Version 1 → 2", "&lt;script&gt;")
    expect(response.body).not_to include("<script>alert")
  end

  it "does not compare a response belonging to another plan" do
    other_task = create(:review_request)
    other_response = CoPlan::Reviews::Respond.call(request: other_task, actor: other_task.reviewer, revision: 1, decision: "approved")
    sign_in_as(reviewer)
    get compare_plan_review_request_path(plan, task, response_id: other_response.id)
    expect(response).to have_http_status(:not_found)
  end
end
