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

    it "keeps the stale base_revision in the conflict re-render so a plain re-save conflicts again" do
      stale = plan.current_revision
      new_version = create(:plan_version, plan: plan, revision: stale + 1,
                           content_markdown: "# Plan\n\nSomeone else edited.\n", actor_id: other_user.id)
      plan.update!(current_plan_version: new_version, current_revision: new_version.revision)

      patch update_content_plan_path(plan), params: {
        content: "# Plan\n\nMy conflicting draft.\n",
        base_revision: stale
      }

      # The hidden field must still carry the stale revision — advancing it
      # here would let an unreviewed second save overwrite the other edit.
      expect(response.body).to include(%(name="base_revision" id="base_revision" value="#{stale}"))

      expect {
        patch update_content_plan_path(plan), params: {
          content: "# Plan\n\nMy conflicting draft.\n",
          base_revision: stale
        }
      }.not_to change(CoPlan::PlanVersion, :count)
      expect(response).to have_http_status(:conflict)
      expect(plan.reload.current_content).to eq("# Plan\n\nSomeone else edited.\n")
    end

    it "overwrites only with explicit overwrite_revision consent" do
      stale = plan.current_revision
      new_version = create(:plan_version, plan: plan, revision: stale + 1,
                           content_markdown: "# Plan\n\nSomeone else edited.\n", actor_id: other_user.id)
      plan.update!(current_plan_version: new_version, current_revision: new_version.revision)

      expect {
        patch update_content_plan_path(plan), params: {
          content: "# Plan\n\nMy conflicting draft.\n",
          base_revision: stale,
          overwrite_revision: new_version.revision
        }
      }.to change(CoPlan::PlanVersion, :count).by(1)

      expect(response).to redirect_to(plan_path(plan))
      expect(plan.reload.current_content).to eq("# Plan\n\nMy conflicting draft.\n")
    end

    it "conflicts again when the plan moved past the consented overwrite_revision" do
      stale = plan.current_revision
      v2 = create(:plan_version, plan: plan, revision: stale + 1,
                  content_markdown: "# Plan\n\nEdit two.\n", actor_id: other_user.id)
      v3 = create(:plan_version, plan: plan, revision: stale + 2,
                  content_markdown: "# Plan\n\nEdit three.\n", actor_id: other_user.id)
      plan.update!(current_plan_version: v3, current_revision: v3.revision)

      # User consented to overwrite v2, but the plan is now at v3.
      expect {
        patch update_content_plan_path(plan), params: {
          content: "# Plan\n\nMy conflicting draft.\n",
          base_revision: stale,
          overwrite_revision: v2.revision
        }
      }.not_to change(CoPlan::PlanVersion, :count)

      expect(response).to have_http_status(:conflict)
      expect(plan.reload.current_content).to eq("# Plan\n\nEdit three.\n")
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

  # The unified editor carries title/tags alongside the body — the whole
  # metadata path rides update_content, not the legacy #update action.
  describe "PATCH update_content with metadata" do
    it "applies title and tag changes alongside content and logs their events" do
      plan.tag_names = ["security"]
      plan.save!

      patch update_content_plan_path(plan), params: {
        content: "# Plan\n\nEdited with metadata.\n",
        base_revision: plan.current_revision,
        plan: { title: "Renamed Plan", tag_names: "security, api-design" }
      }

      expect(response).to redirect_to(plan_path(plan))
      plan.reload
      expect(plan.title).to eq("Renamed Plan")
      expect(plan.tag_names).to contain_exactly("security", "api-design")
      expect(plan.current_content).to eq("# Plan\n\nEdited with metadata.\n")
      expect(plan.plan_events.where(event_type: "title_changed")).to exist
      expect(plan.plan_events.where(event_type: "tag_added").map(&:after_value)).to include("api-design")
    end

    it "says 'Plan updated.' when only metadata changed" do
      patch update_content_plan_path(plan), params: {
        content: plan.current_content,
        base_revision: plan.current_revision,
        plan: { title: "Rename Only" }
      }

      expect(response).to redirect_to(plan_path(plan))
      expect(flash[:notice]).to eq("Plan updated.")
      expect(plan.reload.title).to eq("Rename Only")
    end

    it "says 'No changes to save.' when nothing changed" do
      patch update_content_plan_path(plan), params: {
        content: plan.current_content,
        base_revision: plan.current_revision,
        plan: { title: plan.title }
      }

      expect(response).to redirect_to(plan_path(plan))
      expect(flash[:notice]).to eq("No changes to save.")
    end

    it "persists metadata even when the content save hits a conflict" do
      stale = plan.current_revision
      new_version = create(:plan_version, plan: plan, revision: stale + 1,
                           content_markdown: "# Plan\n\nSomeone else edited.\n", actor_id: other_user.id)
      plan.update!(current_plan_version: new_version, current_revision: new_version.revision)

      patch update_content_plan_path(plan), params: {
        content: "# Plan\n\nMy conflicting draft.\n",
        base_revision: stale,
        plan: { title: "Renamed During Conflict" }
      }

      # The body conflicts, but the rename must not be lost to someone
      # else's edit — metadata applies up front.
      expect(response).to have_http_status(:conflict)
      plan.reload
      expect(plan.title).to eq("Renamed During Conflict")
      expect(plan.plan_events.where(event_type: "title_changed")).to exist
      expect(plan.current_content).to eq("# Plan\n\nSomeone else edited.\n")
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
