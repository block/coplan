require "rails_helper"

RSpec.describe "Analytics instrumentation", type: :request do
  let(:user) { create(:coplan_user) }

  before { sign_in_as(user) }

  describe "page_view" do
    it "tracks a page_view event on successful HTML GETs" do
      plan = create(:plan, :considering, created_by_user: user)

      events = capture_analytics_events { get plan_path(plan) }

      page_views = events.select { |name, _| name == "page_view" }
      expect(page_views.length).to eq(1)
      _, payload = page_views.first
      expect(payload[:user_id]).to eq(user.id)
      expect(payload[:properties]).to include(
        path: plan_path(plan),
        controller: "coplan/plans",
        action: "show"
      )
    end

    it "does not track for turbo-frame requests" do
      create(:plan, :considering, created_by_user: user)

      events = capture_analytics_events do
        get plans_path, headers: { "Turbo-Frame" => "plan-list" }
      end

      expect(events.select { |name, _| name == "page_view" }).to be_empty
    end

    it "does not track agent (non-browser) requests" do
      events = capture_analytics_events do
        get plans_path, headers: { "User-Agent" => "curl/8" }
      end
      expect(events.select { |name, _| name == "page_view" }).to be_empty
    end

    it "does not track non-2xx responses" do
      events = capture_analytics_events { get plan_path("does-not-exist") }

      expect(response).to have_http_status(:not_found)
      expect(events.select { |name, _| name == "page_view" }).to be_empty
    end
  end

  describe "plan_published" do
    it "tracks plan_published when status crosses to considering" do
      plan = create(:plan, :brainstorm, created_by_user: user)

      events = capture_analytics_events do
        patch update_status_plan_path(plan), params: { status: "considering" }
      end

      published = events.select { |name, _| name == "plan_published" }
      expect(published.length).to eq(1)
      _, payload = published.first
      expect(payload[:user_id]).to eq(user.id)
      expect(payload[:properties]).to include(
        plan_id: plan.id,
        previous_status: "brainstorm"
      )
    end

    it "does not track plan_published when status changes between non-considering states" do
      plan = create(:plan, :brainstorm, created_by_user: user)

      events = capture_analytics_events do
        patch update_status_plan_path(plan), params: { status: "abandoned" }
      end

      expect(events.select { |name, _| name == "plan_published" }).to be_empty
    end

    it "does not track plan_published when re-saving status considering" do
      plan = create(:plan, :considering, created_by_user: user)

      events = capture_analytics_events do
        patch update_status_plan_path(plan), params: { status: "considering" }
      end

      expect(events.select { |name, _| name == "plan_published" }).to be_empty
    end

    it "tracks plan_published when the API publishes a plan" do
      plan = create(:plan, :brainstorm, created_by_user: user)
      token = create(:api_token, user: user, raw_token: "publish-token")
      token # ensure persisted

      events = capture_analytics_events do
        patch api_v1_plan_path(plan),
          params: { status: "considering" }.to_json,
          headers: { "Authorization" => "Bearer publish-token", "Content-Type" => "application/json" }
      end

      published = events.select { |name, _| name == "plan_published" }
      expect(published.length).to eq(1)
      _, payload = published.first
      expect(payload[:user_id]).to eq(user.id)
      expect(payload[:properties]).to include(
        plan_id: plan.id,
        previous_status: "brainstorm",
        via: "api"
      )
    end
  end
end
