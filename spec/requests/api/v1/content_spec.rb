require "rails_helper"

RSpec.describe "Api::V1::Content", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:initial_content) { "# Plan\n\nSection one.\n\nSection two.\n" }
  let!(:plan) do
    p = CoPlan::Plan.create!(title: "Test", created_by_user: alice, status: "considering")
    v = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: initial_content,
      actor_type: "human", actor_id: alice.id,
      operations_json: []
    )
    p.update!(current_plan_version: v, current_revision: 1)
    p
  end

  before { alice_token }

  def put_content(body, params: {})
    payload = { base_revision: plan.current_revision, content: body }.merge(params)
    put api_v1_plan_content_path(plan), params: payload, headers: headers, as: :json
  end

  describe "happy path" do
    it "creates a new version with the supplied content" do
      new_body = initial_content.sub("Section one.", "Section ONE rewritten.")

      expect { put_content(new_body) }.to change(CoPlan::PlanVersion, :count).by(1)
      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      expect(body["revision"]).to eq(2)
      expect(body["applied"]).to be > 0
      expect(body["version_id"]).to be_present

      expect(plan.reload.current_content).to eq(new_body)
      expect(plan.current_revision).to eq(2)
    end

    it "returns 200 ok with no_op:true when content is unchanged" do
      expect { put_content(initial_content) }.not_to change(CoPlan::PlanVersion, :count)
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["no_op"]).to be true
      expect(body["applied"]).to eq(0)
      expect(body["revision"]).to eq(1)
    end

    it "accepts change_summary and persists it on the version" do
      new_body = initial_content + "\nappended.\n"
      put_content(new_body, params: { change_summary: "added appendix" })
      expect(response).to have_http_status(:created)

      version = plan.plan_versions.find_by(revision: 2)
      expect(version.change_summary).to eq("added appendix")
    end
  end

  describe "validation" do
    it "returns 422 when base_revision is missing" do
      put api_v1_plan_content_path(plan),
        params: { content: "anything" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/base_revision/)
    end

    it "returns 422 when content key is missing entirely" do
      put api_v1_plan_content_path(plan),
        params: { base_revision: 1 }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/content/)
    end

    it "rejects empty content with 422 (PlanVersion requires content_markdown)" do
      put_content("")
      expect(response).to have_http_status(:unprocessable_content)
      expect(plan.reload.current_revision).to eq(1)
    end
  end

  describe "concurrency" do
    it "returns 409 with current_revision when base_revision is stale" do
      put api_v1_plan_content_path(plan),
        params: { base_revision: 999, content: "anything" },
        headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["error"]).to match(/Stale/)
      expect(body["current_revision"]).to eq(1)
    end
  end

  describe "auth" do
    it "returns 401 without bearer token" do
      put api_v1_plan_content_path(plan),
        params: { base_revision: 1, content: "x" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "anchor preservation through full content replacement" do
    let!(:thread) do
      anchor_text = "Section one."
      CoPlan::CommentThread.create!(
        plan: plan, plan_version: plan.current_plan_version,
        created_by_user: alice,
        anchor_text: anchor_text,
        anchor_revision: 1,
        anchor_start: initial_content.index(anchor_text),
        anchor_end: initial_content.index(anchor_text) + anchor_text.length,
        status: "todo"
      )
    end

    it "shifts unaffected anchors and marks overlapping ones out-of-date" do
      new_body = initial_content.sub("Section one.", "Section ONE rewritten with more text.")
      put_content(new_body)
      expect(response).to have_http_status(:created)

      thread.reload
      expect(thread.out_of_date).to be true
    end
  end
end
