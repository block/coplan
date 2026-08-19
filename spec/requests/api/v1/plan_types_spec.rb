require "rails_helper"

RSpec.describe "Api::V1::PlanTypes", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }

  before do
    alice_token # ensure token exists
  end

  it "requires auth" do
    get api_v1_plan_types_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns every plan type with its template and default tags, sorted by name" do
    create(:plan_type, name: "RFC", description: "Request for comments", default_tags: ["rfc"], template_content: "# RFC\n\n## Problem\n\n## Proposal")
    create(:plan_type, name: "Design Doc", description: "For design documents")

    get api_v1_plan_types_path, headers: headers

    expect(response).to have_http_status(:success)
    types = JSON.parse(response.body)
    expect(types.map { |t| t["name"] }).to eq(["Design Doc", "RFC"])

    rfc = types.last
    expect(rfc["description"]).to eq("Request for comments")
    expect(rfc["default_tags"]).to eq(["rfc"])
    expect(rfc["template_content"]).to include("## Proposal")
  end
end
