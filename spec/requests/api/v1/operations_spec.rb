require "rails_helper"

RSpec.describe "Api::V1::Operations", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }
  let(:lease_token) { SecureRandom.hex(32) }

  before do
    alice_token # ensure token exists
    CoPlan::EditLease.acquire!(
      plan: plan,
      holder_type: "local_agent",
      holder_id: alice_token.id,
      lease_token: lease_token
    )
  end

  it "apply operations creates new version" do
    expect {
      post api_v1_plan_operations_path(plan),
        params: {
          lease_token: lease_token,
          base_revision: plan.current_revision,
          operations: [
            { op: "replace_exact", old_text: "Some content here.", new_text: "Updated content.", count: 1 }
          ]
        },
        headers: headers,
        as: :json
    }.to change(CoPlan::PlanVersion, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["revision"]).to eq(plan.current_revision + 1)
  end

  it "apply operations fails without lease" do
    CoPlan::EditLease.find_by(plan_id: plan.id)&.destroy

    post api_v1_plan_operations_path(plan),
      params: {
        lease_token: "no-lease",
        base_revision: plan.current_revision,
        operations: [{ op: "replace_exact", old_text: "x", new_text: "y", count: 1 }]
      },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:conflict)
  end

  it "apply operations fails on stale revision" do
    post api_v1_plan_operations_path(plan),
      params: {
        lease_token: lease_token,
        base_revision: 999,
        operations: [{ op: "replace_exact", old_text: "x", new_text: "y", count: 1 }]
      },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:conflict)
  end

  it "apply operations fails on invalid operation" do
    post api_v1_plan_operations_path(plan),
      params: {
        lease_token: lease_token,
        base_revision: plan.current_revision,
        operations: [{ op: "replace_exact", old_text: "nonexistent text", new_text: "y", count: 1 }]
      },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "apply replace_section operation creates new version" do
    plan.current_plan_version.update!(content_markdown: "# Title\n\n## Goals\n\nGoal 1.\n\n## Timeline\n\nQ1.")
    expect {
      post api_v1_plan_operations_path(plan),
        params: {
          lease_token: lease_token,
          base_revision: plan.current_revision,
          operations: [
            { op: "replace_section", heading: "## Goals", new_content: "## Goals\n\nNew goals." }
          ]
        },
        headers: headers,
        as: :json
    }.to change(CoPlan::PlanVersion, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["applied"]).to eq(1)
  end

  it "replace_section fails with heading_not_found" do
    post api_v1_plan_operations_path(plan),
      params: {
        lease_token: lease_token,
        base_revision: plan.current_revision,
        operations: [{ op: "replace_section", heading: "## Missing", new_content: "x" }]
      },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to match(/heading_not_found/)
  end

  it "apply operations without lease_token uses direct mode" do
    post api_v1_plan_operations_path(plan),
      params: {
        base_revision: plan.current_revision,
        operations: [{ op: "replace_exact", old_text: "Some content here.", new_text: "Direct edit.", count: 1 }]
      },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:created)
  end
end
