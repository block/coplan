require "rails_helper"

RSpec.describe "Api::V1::Tags", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }

  before do
    alice_token # ensure token exists
  end

  it "index returns tags sorted by plans_count descending" do
    popular = create(:tag, name: "infrastructure")
    niche = create(:tag, name: "experimental")
    plan1 = create(:plan, :considering, created_by_user: alice)
    plan2 = create(:plan, :considering, created_by_user: alice)
    create(:plan_tag, plan: plan1, tag: popular)
    create(:plan_tag, plan: plan2, tag: popular)
    create(:plan_tag, plan: plan1, tag: niche)

    get api_v1_tags_path, headers: headers
    expect(response).to have_http_status(:success)
    tags = JSON.parse(response.body)
    expect(tags.length).to eq(2)
    expect(tags.first["name"]).to eq("infrastructure")
    expect(tags.first["plans_count"]).to eq(2)
    expect(tags.second["name"]).to eq("experimental")
    expect(tags.second["plans_count"]).to eq(1)
  end

  it "index returns empty array when no tags exist" do
    get api_v1_tags_path, headers: headers
    expect(response).to have_http_status(:success)
    tags = JSON.parse(response.body)
    expect(tags).to eq([])
  end

  it "index requires authentication" do
    get api_v1_tags_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "excludes tags only attached to other users' brainstorm plans" do
    bob = create(:coplan_user)
    secret_tag = create(:tag, name: "secret-project")
    visible_tag = create(:tag, name: "public-project")
    brainstorm_plan = create(:plan, created_by_user: bob) # brainstorm by default
    public_plan = create(:plan, :considering, created_by_user: bob)
    create(:plan_tag, plan: brainstorm_plan, tag: secret_tag)
    create(:plan_tag, plan: public_plan, tag: visible_tag)

    get api_v1_tags_path, headers: headers
    tags = JSON.parse(response.body)
    tag_names = tags.map { |t| t["name"] }
    expect(tag_names).to include("public-project")
    expect(tag_names).not_to include("secret-project")
  end

  it "includes tags from the current user's own brainstorm plans" do
    my_tag = create(:tag, name: "my-draft")
    brainstorm_plan = create(:plan, created_by_user: alice)
    create(:plan_tag, plan: brainstorm_plan, tag: my_tag)

    get api_v1_tags_path, headers: headers
    tags = JSON.parse(response.body)
    expect(tags.map { |t| t["name"] }).to include("my-draft")
  end
end
