require "rails_helper"

RSpec.describe "Review evidence API", type: :request do
  let(:author) { create(:coplan_user) }
  let(:plan) { CoPlan::Plans::Create.call(title: "Approval API", content: "Exact bytes", user: author) }
  let(:token) { create(:api_token, user: author, raw_token: "parity-fixture") }
  let(:headers) { token; { "Authorization" => "Bearer parity-fixture" } }
  let(:task) { CoPlan::Reviews::Request.call(plan: plan, reviewer: create(:coplan_user), actor: author) }

  it "reads a coherent exact body, hash, current human decision and cycle without creating read receipts" do
    receipt = CoPlan::Reviews::Respond.call(request: task, actor: task.reviewer, revision: 1, generation: task.generation, decision: "approved")
    counts = [ CoPlan::PlanRead.count, CoPlan::AgentSession.count, CoPlan::Notification.count ]
    get review_evidence_api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:ok)
    data = response.parsed_body
    expect(data.fetch("version")).to include("id" => receipt.plan_version_id, "content_markdown" => "Exact bytes", "content_sha256" => Digest::SHA256.hexdigest("Exact bytes"))
    expect(data.fetch("review_requests").first).to include("generation" => task.generation, "effective_response_id" => receipt.id, "effective_human_decision" => "approved")
    expect(data.fetch("approval_scope").fetch("excludes")).to include("attachments", "title", "child_plans", "embedded_resources")
    expect([ CoPlan::PlanRead.count, CoPlan::AgentSession.count, CoPlan::Notification.count ]).to eq(counts)
  end

  it "dismisses approvals through the direct operations API and rejects stale submissions" do
    task
    CoPlan::Reviews::Respond.call(request: task, actor: task.reviewer, revision: 1, generation: task.generation, decision: "approved")
    CoPlan::PlanRead.record!(plan: plan, reader_type: "api_token", reader_id: token.id, revision: 1)
    post api_v1_plan_operations_path(plan), headers: headers, as: :json,
      params: { base_revision: 1, operations: [ { op: "replace_exact", old_text: "Exact", new_text: "Changed" } ] }
    expect(response).to have_http_status(:created)
    expect(task.reload).to have_attributes(status: "pending", current_response_id: nil)
    expect {
      CoPlan::Reviews::Respond.call(request: task, actor: task.reviewer, revision: 1, generation: 1, decision: "approved", idempotency_key: SecureRandom.uuid)
    }.to raise_error(CoPlan::Reviews::Respond::Conflict)
    get review_evidence_api_v1_plan_path(plan), headers: headers
    expect(response.parsed_body.fetch("version")).to include("revision" => 2, "content_markdown" => "Changed bytes")
    expect(response.parsed_body.fetch("review_requests").first.fetch("effective_response_id")).to be_nil
  end

  it "distinguishes retained task completion from current-version approval when resets are off" do
    plan.update!(reset_reviews_on_change: false)
    receipt = CoPlan::Reviews::Respond.call(request: task, actor: task.reviewer, revision: 1, generation: 1, decision: "approved")
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "New source", base_revision: 1, actor_type: "human", actor_id: author.id)
    get review_evidence_api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:ok)
    data = response.parsed_body
    expect(data.fetch("reset_reviews_on_change")).to be(false)
    expect(data.fetch("version").fetch("revision")).to eq(2)
    expect(data.fetch("review_requests").first).to include("review_status" => "approved", "recorded_response_id" => receipt.id,
      "effective_status" => "pending", "effective_human_decision" => nil, "effective_response_id" => nil)
    expect(data.fetch("review_requests").first.fetch("responses").first).to include("revision" => 1, "plan_version_id" => receipt.plan_version_id)
  end

  it "returns the exact historical source after edits and never substitutes current content" do
    original = plan.current_plan_version
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "New body", base_revision: 1, actor_type: "human", actor_id: author.id)
    get version_api_v1_plan_path(plan, version_id: original.id), headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => original.id, "revision" => 1, "content_markdown" => "Exact bytes")
    get version_api_v1_plan_path(plan, version_id: SecureRandom.uuid), headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "requires authentication and existing plan visibility" do
    get review_evidence_api_v1_plan_path(plan)
    expect(response).to have_http_status(:unauthorized)
    # Drafts are readable by URL under the existing native policy.
    get review_evidence_api_v1_plan_path(SecureRandom.uuid), headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
