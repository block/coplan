require "rails_helper"

RSpec.describe "Api::V1::Comments", type: :request do
  let(:org) { create(:organization) }
  let(:alice) { create(:user, :admin, organization: org) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }
  let(:thread_record) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice) }

  before do
    alice_token # ensure token exists
  end

  it "create comment thread" do
    expect {
      post api_v1_plan_comments_path(plan),
        params: {
          body_markdown: "API comment here",
          agent_name: "Amp",
          start_line: 1,
          end_line: 3
        },
        headers: headers,
        as: :json
    }.to change(CoPlan::CommentThread, :count).by(1).and change(CoPlan::Comment, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["thread_id"]).to be_present
    expect(body["comment_id"]).to be_present
  end

  it "create general comment thread" do
    expect {
      post api_v1_plan_comments_path(plan),
        params: { body_markdown: "General API feedback", agent_name: "Amp" },
        headers: headers,
        as: :json
    }.to change(CoPlan::CommentThread, :count).by(1)
    expect(response).to have_http_status(:created)
  end

  it "reply to thread" do
    expect {
      post reply_api_v1_plan_comment_path(plan, thread_record),
        params: { body_markdown: "API reply", agent_name: "Amp" },
        headers: headers,
        as: :json
    }.to change(CoPlan::Comment, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["thread_id"]).to eq(thread_record.id)
  end

  it "reply to nonexistent thread" do
    post reply_api_v1_plan_comment_path(plan, "nonexistent-id"),
      params: { body_markdown: "Reply" },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:not_found)
  end

  describe "PATCH resolve" do
    it "resolves a thread" do
      patch resolve_api_v1_plan_comment_path(plan, thread_record),
        headers: headers,
        as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("resolved")
      expect(thread_record.reload.status).to eq("resolved")
    end

    it "returns 404 for nonexistent thread" do
      patch resolve_api_v1_plan_comment_path(plan, "nonexistent-id"),
        headers: headers,
        as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH dismiss" do
    it "dismisses a thread" do
      patch dismiss_api_v1_plan_comment_path(plan, thread_record),
        headers: headers,
        as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("dismissed")
      expect(thread_record.reload.status).to eq("dismissed")
    end

    it "returns 404 for nonexistent thread" do
      patch dismiss_api_v1_plan_comment_path(plan, "nonexistent-id"),
        headers: headers,
        as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "returns 403 when user is not the plan author" do
      bob = create(:user, organization: org)
      bob_token = create(:api_token, user: bob, raw_token: "test-token-bob")
      bob_headers = { "Authorization" => "Bearer test-token-bob" }

      patch dismiss_api_v1_plan_comment_path(plan, thread_record),
        headers: bob_headers,
        as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "rejects comment without agent_name" do
    post api_v1_plan_comments_path(plan),
      params: { body_markdown: "Missing agent name" },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["error"]).to include("Agent name")
  end

  it "rejects reply without agent_name" do
    post reply_api_v1_plan_comment_path(plan, thread_record),
      params: { body_markdown: "Missing agent name" },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["error"]).to include("Agent name")
  end

  it "create comment requires auth" do
    post api_v1_plan_comments_path(plan),
      params: { body_markdown: "No auth" },
      as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
