require "rails_helper"

RSpec.describe "Comments", type: :request do
  let(:org) { create(:organization) }
  let(:alice) { create(:user, :admin, organization: org) }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }
  let(:thread_record) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice) }

  before { sign_in_as(alice) }

  it "create reply" do
    expect {
      post plan_comment_thread_comments_path(plan, thread_record), params: {
        comment: { body_markdown: "I agree with this." }
      }
    }.to change(CoPlan::Comment, :count).by(1)
    expect(response).to redirect_to(plan_path(plan))
    comment = CoPlan::Comment.last
    expect(comment.author_type).to eq("human")
    expect(comment.author_id).to eq(alice.id)
  end
end
