require "rails_helper"

RSpec.describe "API document titles", type: :request do
  let(:user) { create(:coplan_user) }
  let!(:token) { create(:api_token, user: user, raw_token: "document-title-test") }
  let(:headers) { { "Authorization" => "Bearer document-title-test" } }
  let(:plan) { CoPlan::Plans::Create.call(user: user, content: "# Saved title\n\nBody", actor_type: "local_agent") }

  def expect_replay(version, previous)
    operations = version.operations_json.map do |operation|
      operation.merge("_pre_resolved_ranges" => [ operation.fetch("resolved_range") ])
    end
    result = CoPlan::Plans::ApplyOperations.call(content: previous, operations: operations)
    expect(result[:content]).to eq(version.content_markdown)
    expect(version.content_sha256).to eq(Digest::SHA256.hexdigest(version.content_markdown))
  end

  it "ignores legacy create titles and returns the canonical content and metadata" do
    post api_v1_plans_path, params: { title: "Ignored", content: "# Content title\n\nBody" }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    created = CoPlan::Plan.find(response.parsed_body.fetch("id"))
    expect(created.title).to eq("Content title")
    get api_v1_plan_path(created), headers: headers
    expect(response.parsed_body).to include("title" => "Content title", "current_content" => "# Content title\n\nBody")
  end

  it "uses Untitled for a new titleless API document even with legacy metadata" do
    post api_v1_plans_path, params: { title: "Ignored", content: "Body" }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    created = CoPlan::Plan.find(response.parsed_body.fetch("id"))
    expect(created.current_content).to eq("# Untitled\n\nBody")
  end

  [ false, true ].each do |live|
    it "repairs a removed heading on #{live ? 'live-session commit' : 'direct operations'} with replayable history" do
      previous = plan.current_content
      params = { base_revision: 1, operations: [ { op: "replace_exact", old_text: "# Saved title\n\n", new_text: "", count: 1 } ] }
      if live
        post api_v1_plan_sessions_path(plan), headers: headers, as: :json
        expect(response).to have_http_status(:created)
        params[:session_id] = response.parsed_body.fetch("id")
      end
      post api_v1_plan_operations_path(plan), params: params, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      if live
        post commit_api_v1_plan_session_path(plan, params[:session_id]), headers: headers, as: :json
        expect(response).to have_http_status(:ok)
      end
      expect(plan.reload.title).to eq("Saved title")
      expect(plan.current_content).to eq(previous)
      expect_replay(plan.current_plan_version, previous)
      get api_v1_plan_path(plan), headers: headers
      expect(response.parsed_body).to include("current_content" => previous, "title" => "Saved title")
    end
  end
end
