require "rails_helper"

RSpec.describe "Plans", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:bob) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }
  let(:brainstorm_plan) { create(:plan, :brainstorm, created_by_user: alice) }

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

  it "index filters to my plans" do
    plan # created by alice
    bobs_plan = create(:plan, :considering, created_by_user: bob)
    get plans_path(scope: "mine")
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
    expect(response.body).not_to include(bobs_plan.title)
  end

  it "index filters by tag" do
    plan.tag_names = ["infra"]
    other = create(:plan, :considering, created_by_user: alice, title: "Other Plan")
    other.tag_names = ["frontend"]
    get plans_path(tag: "infra")
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
    expect(response.body).not_to include("Other Plan")
  end

  it "index shows tag badges on plan cards" do
    plan.tag_names = ["infra", "api"]
    get plans_path
    expect(response.body).to include("badge--tag")
    expect(response.body).to include("infra")
    expect(response.body).to include("api")
  end

  it "index shows active tag filter bar" do
    plan.tag_names = ["infra"]
    get plans_path(tag: "infra")
    expect(response.body).to include("active-filter")
    expect(response.body).to include("infra")
    expect(response.body).to include("Clear")
  end

  it "show plan renders tag badges in header" do
    plan.tag_names = ["infra", "security"]
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("badge--tag")
    expect(response.body).to include("infra")
    expect(response.body).to include("security")
  end

  it "show plan renders successfully" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
  end

  it "show plan renders plan content" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("plan-layout__content")
  end

  it "show plan renders content navigation sidebar" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('class="content-nav"')
    expect(response.body).to include('data-coplan--content-nav-target="sidebar"')
    expect(response.body).to include('data-coplan--content-nav-target="list"')
    expect(response.body).to include("content-nav-show-btn")
  end

  it "show plan wires up both text-selection and content-nav controllers" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('data-controller="coplan--text-selection coplan--content-nav"')
  end

  it "show plan shares content target between controllers" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('data-coplan--content-nav-target="content"')
    expect(response.body).to include('data-coplan--text-selection-target="content"')
  end

  it "show plan without content does not render content nav sidebar" do
    empty_plan = create(:plan, :considering, created_by_user: alice)
    empty_plan.current_plan_version.update_columns(content_markdown: "", content_sha256: Digest::SHA256.hexdigest(""))
    get plan_path(empty_plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("empty-state")
    expect(response.body).not_to include('class="content-nav"')
  end

  it "show plan includes Open Graph meta tags" do
    get plan_path(plan)
    expect(response.body).to include('property="og:title"')
    expect(response.body).to include('property="og:description"')
    expect(response.body).to include('property="og:site_name"')
    expect(response.body).to include('name="twitter:card"')
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

  it "update plan updates title without creating a version" do
    plan # trigger creation
    expect {
      patch plan_path(plan), params: {
        plan: { title: "Updated Title" }
      }
    }.not_to change(CoPlan::PlanVersion, :count)
    plan.reload
    expect(plan.title).to eq("Updated Title")
    expect(response).to redirect_to(plan_path(plan))
  end

  it "can view brainstorm plan as non-author" do
    sign_in_as(bob)
    get plan_path(brainstorm_plan)
    expect(response).to have_http_status(:ok)
  end

  describe "onboarding banner" do
    it "shows banner when user has no plans" do
      sign_in_as(bob)
      get plans_path
      expect(response.body).to include("onboarding-banner")
    end

    it "hides banner when user has created a plan" do
      plan # alice has a plan
      get plans_path
      expect(response.body).not_to include("onboarding-banner")
    end

    it "hides banner when onboarding_banner config is nil" do
      sign_in_as(bob)
      original = CoPlan.configuration.onboarding_banner
      CoPlan.configuration.onboarding_banner = nil
      get plans_path
      expect(response.body).not_to include("onboarding-banner")
      CoPlan.configuration.onboarding_banner = original
    end

    it "displays custom banner text from configuration" do
      sign_in_as(bob)
      original = CoPlan.configuration.onboarding_banner
      CoPlan.configuration.onboarding_banner = "Custom onboarding message"
      get plans_path
      expect(response.body).to include("Custom onboarding message")
      CoPlan.configuration.onboarding_banner = original
    end
  end
end
