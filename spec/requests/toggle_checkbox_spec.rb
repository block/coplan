require "rails_helper"

RSpec.describe "Toggle Checkbox", type: :request do
  let(:user) { create(:coplan_user) }
  let(:other_user) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: user) }

  before do
    sign_in_as(user)
    plan.current_plan_version.update!(content_markdown: "# Tasks\n\n- [ ] Buy milk\n- [x] Write tests\n- [ ] Deploy")
  end

  describe "PATCH toggle_checkbox" do
    it "checks an unchecked checkbox and creates a new version" do
      expect {
        patch toggle_checkbox_plan_path(plan), params: {
          old_text: "- [ ] Buy milk",
          new_text: "- [x] Buy milk",
          base_revision: plan.current_revision
        }, as: :json
      }.to change(CoPlan::PlanVersion, :count).by(1)

      expect(response).to have_http_status(:ok)
      data = response.parsed_body
      expect(data["revision"]).to eq(plan.current_revision + 1)

      plan.reload
      expect(plan.current_content).to include("- [x] Buy milk")
    end

    it "unchecks a checked checkbox" do
      patch toggle_checkbox_plan_path(plan), params: {
        old_text: "- [x] Write tests",
        new_text: "- [ ] Write tests",
        base_revision: plan.current_revision
      }, as: :json

      expect(response).to have_http_status(:ok)
      plan.reload
      expect(plan.current_content).to include("- [ ] Write tests")
    end

    it "attributes the version to the current user" do
      patch toggle_checkbox_plan_path(plan), params: {
        old_text: "- [ ] Buy milk",
        new_text: "- [x] Buy milk",
        base_revision: plan.current_revision
      }, as: :json

      version = plan.reload.current_plan_version
      expect(version.actor_type).to eq("human")
      expect(version.actor_id).to eq(user.id)
      expect(version.change_summary).to eq("Toggle checkbox")
    end

    it "returns 409 on stale base_revision" do
      stale_revision = plan.current_revision
      # Simulate a concurrent edit by bumping the revision
      new_version = create(:plan_version, plan: plan, revision: plan.current_revision + 1,
                           content_markdown: plan.current_content, actor_id: user.id)
      plan.update!(current_plan_version: new_version, current_revision: new_version.revision)

      patch toggle_checkbox_plan_path(plan), params: {
        old_text: "- [ ] Buy milk",
        new_text: "- [x] Buy milk",
        base_revision: stale_revision
      }, as: :json

      expect(response).to have_http_status(:conflict)
    end

    it "returns 422 when old_text is missing" do
      patch toggle_checkbox_plan_path(plan), params: {
        new_text: "- [x] Buy milk",
        base_revision: plan.current_revision
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when payload is not a checkbox toggle" do
      patch toggle_checkbox_plan_path(plan), params: {
        old_text: "arbitrary text to replace",
        new_text: "sneaky replacement",
        base_revision: plan.current_revision
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("task list")
    end

    it "returns 422 when old_text is not found in content" do
      patch toggle_checkbox_plan_path(plan), params: {
        old_text: "- [ ] Nonexistent task",
        new_text: "- [x] Nonexistent task",
        base_revision: plan.current_revision
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "allows toggle from non-author user" do
      sign_in_as(other_user)

      patch toggle_checkbox_plan_path(plan), params: {
        old_text: "- [ ] Buy milk",
        new_text: "- [x] Buy milk",
        base_revision: plan.current_revision
      }, as: :json

      expect(response).to have_http_status(:ok)
    end
  end
end
