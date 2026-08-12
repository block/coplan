require "rails_helper"

RSpec.describe "AnchorSuggestions", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:bob) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }

  before { sign_in_as(alice) }

  it "returns the span the AI identified" do
    allow(CoPlan::Ai).to receive(:call).and_return("world domination")

    post plan_anchor_suggestions_path(plan),
      params: { transcript: "this bit is too grand", excerpt: "Our goal is world domination by Q3." },
      as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["anchor_text"]).to eq("world domination")
  end

  it "returns nothing rather than an error when the AI can't help" do
    allow(CoPlan::Ai).to receive(:call).and_raise(CoPlan::Ai::Error, "not configured")

    post plan_anchor_suggestions_path(plan),
      params: { transcript: "too formal", excerpt: "Our goal is world domination by Q3." },
      as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["anchor_text"]).to be_nil
  end

  # Only what was on screen goes to the model — narrower is more accurate,
  # cheaper, and sends less of the document off the box.
  it "sends the visible excerpt, not the whole document" do
    expect(CoPlan::Ai).to receive(:call) do |system_prompt:, user_content:|
      expect(user_content).to include("only this paragraph was visible")
      expect(user_content).not_to include(plan.current_content)
      expect(system_prompt).to include("exact span")
      "only this paragraph was visible"
    end

    post plan_anchor_suggestions_path(plan),
      params: { transcript: "tighten this", excerpt: "only this paragraph was visible" },
      as: :json

    expect(JSON.parse(response.body)["anchor_text"]).to eq("only this paragraph was visible")
  end

  it "falls back to the plan content when the client sends no excerpt" do
    expect(CoPlan::Ai).to receive(:call) do |user_content:, **|
      expect(user_content).to include(plan.current_content.truncate(50, omission: ""))
      "NONE"
    end

    post plan_anchor_suggestions_path(plan), params: { transcript: "tighten this" }, as: :json

    expect(JSON.parse(response.body)["anchor_text"]).to be_nil
  end

  # Plans are readable by link (PlanPolicy#show? is true, same as
  # commenting), so the boundary that matters here is being signed in at
  # all — an anonymous visitor must not be able to spend AI calls.
  it "does not run for a signed-out visitor" do
    reset! # drops the signed-in session established above

    expect(CoPlan::Ai).not_to receive(:call)
    post plan_anchor_suggestions_path(plan), params: { transcript: "hi" }, as: :json

    expect(response).not_to have_http_status(:ok)
  end
end
