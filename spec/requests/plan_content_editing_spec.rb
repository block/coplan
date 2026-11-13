require "rails_helper"

RSpec.describe "Plan content editing (web UI)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  after { travel_back }

  let(:author) { create(:coplan_user) }
  let(:other_user) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: author) }

  before do
    sign_in_as(author)
    set_version_fixture(plan.current_plan_version, content_markdown: "# Plan\n\nOriginal body.\n")
  end

  describe "GET legacy edit URL" do
    it "redirects to inline editing on the document" do
      get plan_legacy_edit_page_path(plan)

      expect(response).to redirect_to(plan_page_path(plan, edit: 1))
      follow_redirect!
      expect(response.body).to include("Original body.")
      expect(response.body).to include(%(name="base_revision"))
    end

    it "rejects non-authors" do
      sign_in_as(other_user)
      get plan_legacy_edit_page_path(plan)
      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "GET content_body" do
    it "refreshes stale rendered fragments after 15 minutes without changing the plan" do
      set_version_fixture(plan.current_plan_version, content_markdown: "# 1 Overview\n\nOpening text.\n")
      cache = ActiveSupport::Cache::MemoryStore.new
      allow_any_instance_of(CoPlan::PlansController).to receive(:perform_caching).and_return(true)
      allow_any_instance_of(CoPlan::PlansController).to receive(:cache_store).and_return(cache)
      # Simulate an older renderer's output, retaining the real cache expiry.
      strip_alias = true
      allow(cache).to receive(:write).and_wrap_original do |write, key, value, options|
        value = value.gsub(/<span[^>]*data-heading-alias[^>]*><\/span>/, "") if strip_alias
        write.call(key, value, options)
      end
      get content_body_plan_path(plan)
      strip_alias = false
      get content_body_plan_path(plan)
      expect(Nokogiri::HTML.fragment(response.body).at_css("#section-1")).to be_nil

      travel 15.minutes + 1.second
      get content_body_plan_path(plan)
      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML.fragment(response.body).at_css("h1#plan-title #section-1")).to be_present
    end

    it "returns the latest rendered body and revision without caching" do
      get content_body_plan_path(plan)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Original body.")
      expect(response.headers["X-CoPlan-Revision"]).to eq(plan.current_revision.to_s)
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "allows a non-author with the URL to read an unlisted draft" do
      sign_in_as(other_user)
      plan.update!(visibility: "draft")

      get content_body_plan_path(plan)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Original body.")
    end
  end

  describe "GET comments_body" do
    it "keeps a displaced comment visible after its quote changes" do
      thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Original body.")
      thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Keep this comment")
      thread.update_columns(out_of_date: true)

      get comments_body_plan_path(plan)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Comments on earlier text", "Keep this comment", thread.id)
      expect(response.headers["Cache-Control"]).to include("no-store")
    end
  end

  describe "PATCH update_content" do
    it "creates a new human-authored version and immediately refreshes cached content" do
      allow_any_instance_of(CoPlan::PlansController).to receive(:perform_caching).and_return(true)
      allow_any_instance_of(CoPlan::PlansController).to receive(:cache_store).and_return(ActiveSupport::Cache::MemoryStore.new)
      get content_body_plan_path(plan)
      expect(response.body).to include("Original body.")

      expect {
        patch update_content_plan_path(plan), params: {
          content: "# Plan\n\nEdited body.\n",
          base_revision: plan.current_revision,
          change_summary: "Tightened wording"
        }
      }.to change(CoPlan::PlanVersion, :count).by(1)

      expect(response).to redirect_to(plan_page_path(plan))
      plan.reload
      expect(plan.current_content).to eq("# Plan\n\nEdited body.\n")
      version = plan.current_plan_version
      expect(version.actor_type).to eq("human")
      expect(version.actor_id).to eq(author.id)
      expect(version.change_summary).to eq("Tightened wording")
      get content_body_plan_path(plan)
      expect(response.body).to include("Edited body.")
      expect(response.body).not_to include("Original body.")
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
      expect(response).to redirect_to(plan_page_path(plan))
    end

    it "re-renders the editor with the draft preserved on a stale base_revision" do
      stale = plan.current_revision
      new_version = create(:plan_version, plan: plan, revision: stale + 1,
                           content_markdown: "# Plan\n\nSomeone else edited.\n", actor_id: other_user.id)
      plan.update!(current_plan_version: new_version, current_revision: new_version.revision)

      events_before = plan.plan_events.where(event_type: "title_changed").count
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

      events_before = plan.plan_events.where(event_type: "title_changed").count
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

      expect(response).to redirect_to(plan_page_path(plan))
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
    [ false, true ].each do |edit_body|
      it "broadcasts an inline rename with body editing #{edit_body}" do
        targets = []
        allow(CoPlan::Broadcaster).to receive(:replace_to) { |_plan, **kwargs| targets << kwargs[:target] }

        patch update_content_plan_path(plan), params: {
          content: "# Renamed inline\n\n#{edit_body ? "Updated body." : "Original body."}",
          base_revision: plan.current_revision,
          plan: { title: "Renamed inline" }
        }, as: :json

        expect(response).to have_http_status(:ok)
        expect(targets).to include("plan-nav-context")
      end
    end

    it "does not broadcast the document title for tag-only editor saves" do
      targets = []
      allow(CoPlan::Broadcaster).to receive(:replace_to) { |_plan, **kwargs| targets << kwargs[:target] }

      patch update_content_plan_path(plan), params: {
        content: plan.current_content, base_revision: plan.current_revision,
        plan: { tag_names: "infra" }
      }, as: :json

      expect(response).to have_http_status(:ok)
      expect(targets).to include("plan-header")
      expect(targets).not_to include("plan-title")
    end

    it "applies title and tag changes alongside content and logs their events" do
      plan.tag_names = [ "security" ]
      plan.save!

      patch update_content_plan_path(plan), params: {
        content: "# Renamed Plan\n\nEdited with metadata.\n",
        base_revision: plan.current_revision,
        plan: { title: "Renamed Plan", tag_names: "security, api-design" }
      }

      # Retitling reslugs the document — the redirect lands on its new
      # address, not the one it had going in.
      expect(response).to redirect_to(plan_page_path(plan.reload))
      expect(plan.title).to eq("Renamed Plan")
      expect(plan.tag_names).to contain_exactly("security", "api-design")
      expect(plan.current_content).to eq("# Renamed Plan\n\nEdited with metadata.\n")
      expect(plan.current_plan_version.content_markdown).to start_with("# Renamed Plan")
      expect(plan.plan_events.where(event_type: "tag_added").map(&:after_value)).to include("api-design")
    end

    it "ignores a legacy title-only change" do
      original_title = plan.title
      patch update_content_plan_path(plan), params: {
        content: plan.current_content,
        base_revision: plan.current_revision,
        plan: { title: "Rename Only" }
      }

      expect(response).to redirect_to(plan_page_path(plan.reload))
      expect(flash[:notice]).to eq("No changes to save.")
      expect(plan.title).to eq(original_title)
    end

    it "says 'No changes to save.' when nothing changed" do
      patch update_content_plan_path(plan), params: {
        content: plan.current_content,
        base_revision: plan.current_revision,
        plan: { title: plan.title }
      }

      expect(response).to redirect_to(plan_page_path(plan))
      expect(flash[:notice]).to eq("No changes to save.")
    end

    it "keeps metadata atomic with content when saving hits a conflict" do
      stale = plan.current_revision
      new_version = create(:plan_version, plan: plan, revision: stale + 1,
                           content_markdown: "# Plan\n\nSomeone else edited.\n", actor_id: other_user.id)
      plan.update!(current_plan_version: new_version, current_revision: new_version.revision)

      events_before = plan.plan_events.where(event_type: "title_changed").count
      patch update_content_plan_path(plan), params: {
        content: "# Plan\n\nMy conflicting draft.\n",
        base_revision: stale,
        plan: { title: "Renamed During Conflict" }
      }

      # A failed save must not partially change the document.
      expect(response).to have_http_status(:conflict)
      plan.reload
      expect(plan.title).not_to eq("Renamed During Conflict")
      expect(plan.plan_events.where(event_type: "title_changed").count).to eq(events_before)
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
      plan.tag_names = [ "security" ]
      plan.save!

      patch plan_path(plan), params: { plan: { title: plan.title, tag_names: "security, api-design" } }

      expect(response).to redirect_to(plan_page_path(plan))
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
      original_title = plan.title
      plan.tag_names = [ "security" ]
      plan.save!

      patch plan_path(plan), params: { plan: { title: "New title" } }

      expect(plan.reload.tag_names).to contain_exactly("security")
      expect(plan.title).to eq(original_title)
    end
  end
end
