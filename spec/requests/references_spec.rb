require "rails_helper"

# Web references endpoints. Adding a reference is a contribution (like a
# comment) — open to any signed-in user; removal stays with people who can
# edit the plan.
RSpec.describe "References (web)", type: :request do
  let(:author) { create(:coplan_user) }
  let(:visitor) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: author) }

  describe "POST /plans/:plan_id/references" do
    it "lets a non-author contribute a reference, crediting them as actor" do
      sign_in_as(visitor)

      expect {
        post plan_references_path(plan), params: {
          reference: { url: "https://github.com/squareup/contributed", title: "Contributed" }
        }
      }.to change(plan.references, :count).by(1)

      event = plan.plan_events.where(event_type: "reference_added").last
      expect(event.actor_user).to eq(visitor)
    end

    it "rejects signed-out visitors" do
      expect {
        post plan_references_path(plan), params: {
          reference: { url: "https://github.com/squareup/anon" }
        }
      }.not_to change(CoPlan::Reference, :count)
      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("sign_in")
    end
  end

  describe "DELETE /plans/:plan_id/references/:id" do
    let!(:reference) do
      plan.references.create!(url: "https://github.com/squareup/x", title: "X",
        reference_type: "repository", source: "explicit")
    end

    it "refuses removal by a non-author" do
      sign_in_as(visitor)
      expect {
        delete plan_reference_path(plan, reference)
      }.not_to change(plan.references, :count)
      expect(response).to have_http_status(:not_found) # authz failures don't confirm the resource exists
      expect(plan.references.exists?(reference.id)).to be(true)
    end

    it "lets the author remove it" do
      sign_in_as(author)
      expect {
        delete plan_reference_path(plan, reference)
      }.to change(plan.references, :count).by(-1)
    end
  end
end
