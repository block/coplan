require "rails_helper"

RSpec.describe "Plan content editing (web UI)", type: :request do
  let(:author) { create(:coplan_user) }
  let(:other_user) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: author) }

  before do
    sign_in_as(author)
    plan.current_plan_version.update!(content_markdown: "# Plan\n\nOriginal body.\n")
  end

  describe "GET edit_content" do
    it "renders the editor with the current content and revision" do
      get edit_content_plan_path(plan)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Original body.")
      expect(response.body).to include(%(name="base_revision"))
    end

    it "rejects non-authors" do
      sign_in_as(other_user)
      get edit_content_plan_path(plan)
      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "PATCH update_content" do
    it "creates a new human-authored version through ReplaceContent" do
      expect {
        patch update_content_plan_path(plan), params: {
          content: "# Plan\n\nEdited body.\n",
          base_revision: plan.current_revision,
          change_summary: "Tightened wording"
        }
      }.to change(CoPlan::PlanVersion, :count).by(1)

      expect(response).to redirect_to(plan_path(plan))
      plan.reload
      expect(plan.current_content).to eq("# Plan\n\nEdited body.\n")
      version = plan.current_plan_version
      expect(version.actor_type).to eq("human")
      expect(version.actor_id).to eq(author.id)
      expect(version.change_summary).to eq("Tightened wording")
    end

    it "defaults the change summary" do
      patch update_content_plan_path(plan), params: {
        content: "# Plan\n\nEdited.\n",
        base_revision: plan.current_revision
      }
      expect(plan.reload.current_plan_version.change_summary).to eq("Edited in web UI")
    end

    it "redirects without a new version when content is unchanged" do
      expect {
        patch update_content_plan_path(plan), params: {
          content: plan.current_content,
          base_revision: plan.current_revision
        }
      }.not_to change(CoPlan::PlanVersion, :count)
      expect(response).to redirect_to(plan_path(plan))
    end

    it "re-renders the editor with the draft preserved on a stale base_revision" do
      stale = plan.current_revision
      new_version = create(:plan_version, plan: plan, revision: stale + 1,
                           content_markdown: "# Plan\n\nSomeone else edited.\n", actor_id: other_user.id)
      plan.update!(current_plan_version: new_version, current_revision: new_version.revision)

      patch update_content_plan_path(plan), params: {
        content: "# Plan\n\nMy conflicting draft.\n",
        base_revision: stale
      }

      expect(response).to have_http_status(:conflict)
      expect(response.body).to include("My conflicting draft.")
      expect(response.body).to include("was updated to v#{plan.current_revision}")
      expect(plan.reload.current_content).to eq("# Plan\n\nSomeone else edited.\n")
    end

    it "rejects non-authors" do
      sign_in_as(other_user)
      patch update_content_plan_path(plan), params: {
        content: "# Hijacked\n",
        base_revision: plan.current_revision
      }
      expect(response).not_to have_http_status(:ok)
      expect(plan.reload.current_content).to eq("# Plan\n\nOriginal body.\n")
    end
  end

  describe "POST preview" do
    it "renders submitted markdown without interactive checkboxes" do
      post preview_plan_path(plan), params: { content: "# Preview\n\n- [ ] task" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Preview</h1>")
      expect(response.body).not_to include("coplan--checkbox#toggle")
    end

    it "is available to any viewer with show access" do
      sign_in_as(other_user)
      post preview_plan_path(plan), params: { content: "hello" }, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH update with tags" do
    it "updates tags from a comma-separated list and logs events" do
      plan.tag_names = ["security"]
      plan.save!

      patch plan_path(plan), params: { plan: { title: plan.title, tag_names: "security, api-design" } }

      expect(response).to redirect_to(plan_path(plan))
      expect(plan.reload.tag_names).to contain_exactly("security", "api-design")
      events = plan.plan_events.where(event_type: "tag_added")
      expect(events.map(&:after_value)).to include("api-design")
    end

    it "removes tags omitted from the list" do
      plan.tag_names = %w[security api-design]
      plan.save!

      patch plan_path(plan), params: { plan: { title: plan.title, tag_names: "security" } }

      expect(plan.reload.tag_names).to contain_exactly("security")
      expect(plan.plan_events.where(event_type: "tag_removed").map(&:before_value)).to include("api-design")
    end

    it "leaves tags untouched when the field is absent" do
      plan.tag_names = ["security"]
      plan.save!

      patch plan_path(plan), params: { plan: { title: "New title" } }

      expect(plan.reload.tag_names).to contain_exactly("security")
      expect(plan.title).to eq("New title")
    end
  end
end
