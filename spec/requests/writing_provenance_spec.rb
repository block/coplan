require "rails_helper"

RSpec.describe "Writing provenance", type: :request do
  let(:user) { create(:coplan_user) }
  let(:plan) { CoPlan::Plans::Create.call(title: "Provenance", content: "AI body", user: user, actor_type: "local_agent", agent_name: "Claude") }

  before { sign_in_as(user) }

  it "serves named contributors lazily without a separate agent section" do
    plan
    expect(CoPlan::Plans::WritingProvenance).not_to receive(:call)
    get plan_page_path(plan)
    expect(response.body).to include("Entirely AI written. Show writing provenance")
    expect(response.body).not_to include("AI agents and models")
    get writing_provenance_plan_path(plan)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Unknown", "Claude", "Inspect writing")
    expect(response.body).not_to include("AI agents and models", "<summary>AI")
  end

  it "exposes cached API summaries and optional compact Unicode ranges" do
    token, raw = CoPlan::ApiToken.create_with_raw_token(user: user, name: "Read provenance", agent_name: "Codex")
    headers = { "Authorization" => "Bearer #{raw}" }
    get api_v1_plan_path(plan), headers: headers
    expect(response.parsed_body.fetch("writing_provenance").dig("shares", "ai")).to eq(1.0)
    get writing_provenance_api_v1_plan_path(plan), params: { ranges: "1" }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("revision" => 1, "offset_unit" => "unicode_codepoints")
    expect(response.parsed_body.fetch("runs").sum(&:first)).to eq(plan.current_content.length)
    expect(response.parsed_body.to_json).not_to include(raw, token.token_digest)
  end

  it "requires authentication for details and API ranges" do
    delete sign_out_path
    get writing_provenance_plan_path(plan)
    expect(response).to have_http_status(:redirect)
    get writing_provenance_api_v1_plan_path(plan)
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns highlights for the exact saved revision on explicit request" do
    get writing_provenance_plan_path(plan), headers: { "Accept" => "application/json" }
    data = response.parsed_body
    expect(data.fetch("revision")).to eq(1)
    expect(data.dig("rendered", "text")).to eq("AIbody")
    key = data.dig("rendered", "runs").first.last
    expect(data.dig("rendered", "sources", key)).to include("kind" => "ai", "origin_revision" => 1)
  end

  it "queues legacy reconstruction only when details are requested" do
    plan.current_plan_version.update_columns(writing_provenance: nil)
    plan.update_columns(writing_provenance_summary: nil)
    expect { get plan_page_path(plan) }.not_to have_enqueued_job(CoPlan::WritingProvenanceJob)
    expect { get writing_provenance_plan_path(plan) }.to have_enqueued_job(CoPlan::WritingProvenanceJob).with(plan_id: plan.id)
    expect(response).to have_http_status(:accepted)
  end

  it "accepts editor input evidence without changing human actor semantics" do
    post plans_path, params: { plan: { title: "Typed and pasted" }, content: "Typed Pasted",
      input_sources: { runs: [ [ 6, "human" ], [ 6, "unknown" ] ] } }, as: :json
    expect(response).to have_http_status(:ok)
    created = CoPlan::Plan.find(response.parsed_body.fetch("id"))
    expect(created.current_plan_version.actor_type).to eq("human")
    expect(created.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 0, "unknown" => 6)
  end
end
