require "rails_helper"

RSpec.describe "Plans", type: :request do
  let(:org) { create(:organization) }
  let(:alice) { create(:user, :admin, organization: org) }
  let(:bob) { create(:user, organization: org) }
  let(:plan) { create(:plan, :considering, organization: org, created_by_user: alice) }
  let(:brainstorm_plan) { create(:plan, :brainstorm, organization: org, created_by_user: alice) }

  before { sign_in_as(alice) }

  it "index shows plans" do
    plan # trigger creation
    get plans_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
  end

  it "index filters by status" do
    plan # trigger creation
    get plans_path(status: "considering")
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
  end

  it "show plan renders successfully" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
  end

  it "show plan displays comments sidebar" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("comment-threads-list")
  end

  it "show plan includes turbo stream subscription" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("turbo-cable-stream-source")
  end

  it "edit plan" do
    get edit_plan_path(plan)
    expect(response).to have_http_status(:success)
  end

  it "update plan creates new version" do
    plan # trigger creation
    expect {
      patch plan_path(plan), params: {
        plan: { title: "Updated Title", content_markdown: "# Updated", change_summary: "Revised" }
      }
    }.to change(PlanVersion, :count).by(1)
    plan.reload
    expect(plan.title).to eq("Updated Title")
    expect(plan.current_revision).to eq(2)
    expect(response).to redirect_to(plan_path(plan))
  end

  it "cannot view brainstorm plan as non-author" do
    sign_in_as(bob)
    get plan_path(brainstorm_plan)
    expect(response).to have_http_status(:not_found)
  end

  it "update marks existing threads as out of date" do
    thread = create(:comment_thread, :with_anchor, plan: plan, organization: org, plan_version: plan.current_plan_version, created_by_user: alice, anchor_text: "original roadmap text")
    expect(thread).not_to be_out_of_date

    patch plan_path(plan), params: {
      plan: { title: plan.title, content_markdown: "# Updated content", change_summary: "Updated" }
    }

    thread.reload
    expect(thread).to be_out_of_date
    expect(thread.out_of_date_since_version_id).not_to be_nil
  end
end
