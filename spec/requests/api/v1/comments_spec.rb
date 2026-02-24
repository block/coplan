require "rails_helper"

RSpec.describe "Api::V1::Comments", type: :request do
  let(:org) { create(:organization) }
  let(:alice) { create(:user, :admin, organization: org) }
  let(:alice_token) { create(:api_token, organization: org, user: alice, raw_token: "test-token-alice") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:plan) { create(:plan, :considering, organization: org, created_by_user: alice) }
  let(:thread_record) { create(:comment_thread, plan: plan, organization: org, plan_version: plan.current_plan_version, created_by_user: alice) }

  before do
    alice_token # ensure token exists
  end

  it "create comment thread" do
    expect {
      post api_v1_plan_comments_path(plan),
        params: {
          body_markdown: "API comment here",
          start_line: 1,
          end_line: 3
        },
        headers: headers,
        as: :json
    }.to change(CommentThread, :count).by(1).and change(Comment, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["thread_id"]).to be_present
    expect(body["comment_id"]).to be_present
  end

  it "create general comment thread" do
    expect {
      post api_v1_plan_comments_path(plan),
        params: { body_markdown: "General API feedback" },
        headers: headers,
        as: :json
    }.to change(CommentThread, :count).by(1)
    expect(response).to have_http_status(:created)
  end

  it "reply to thread" do
    expect {
      post reply_api_v1_plan_comment_path(plan, thread_record),
        params: { body_markdown: "API reply" },
        headers: headers,
        as: :json
    }.to change(Comment, :count).by(1)
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

  it "create comment requires auth" do
    post api_v1_plan_comments_path(plan),
      params: { body_markdown: "No auth" },
      as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
