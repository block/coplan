require "rails_helper"

RSpec.describe "Admin pages", type: :request do
  # Each page gets a real row so both the index table and show view render
  # their record-dependent content. Keep this list in sync with the registry;
  # the coverage example below fails when a new admin page is registered.
  records = {
    "agent_events" => -> {
      CoPlan::AgentEvent.create!(
        plan: create(:plan), api_token: create(:api_token), event_type: "comment.created"
      )
    },
    "agent_harnesses" => -> { create(:agent_harness) },
    "agent_sessions" => -> {
      CoPlan::AgentSession.create!(
        plan: create(:plan), api_token: create(:api_token), agent_name: "Test agent", state: "watching"
      )
    },
    "api_tokens" => -> { create(:api_token) },
    "comment_threads" => -> { create(:comment_thread) },
    "plan_comments" => -> { create(:comment) },
    "edit_leases" => -> { create(:edit_lease) },
    "edit_sessions" => -> { create(:edit_session) },
    "embed_domains" => -> { CoPlan::EmbedDomain.create!(hostname: "embed.example.com") },
    "folders" => -> { create(:folder) },
    "library_events" => -> {
      CoPlan::LibraryEvent.create!(
        library: create(:coplan_user).library, event_type: "folder_created", actor_type: "human"
      )
    },
    "notification_deliveries" => -> { create(:notification_delivery) },
    "notifications" => -> { create(:notification) },
    "plan_events" => -> { create(:plan_event) },
    "plan_reads" => -> {
      plan = create(:plan)
      CoPlan::PlanRead.create!(
        plan: plan, reader_type: "user", reader_id: plan.created_by_user_id,
        last_seen_revision: plan.current_revision, last_seen_at: Time.current
      )
    },
    "plan_types" => -> { create(:plan_type) },
    "plan_versions" => -> { create(:plan).current_plan_version },
    "plans" => -> { create(:plan) },
    "references" => -> { create(:reference) },
    "tags" => -> { create(:tag) },
    "users" => -> { create(:coplan_user) }
  }

  let(:admin) { create(:coplan_user, admin: true) }

  before { sign_in_as(admin) }

  it "covers every registered admin page" do
    Rails.application.routes.routes # ActiveAdmin loads registrations while drawing routes.
    registered_pages = ActiveAdmin.application.namespace(:admin).resources
      # ActiveAdmin keeps its internal comments resource registered even with comments disabled.
      .reject { |resource| resource.is_a?(ActiveAdmin::Resource) && resource.resource_class == ActiveAdmin::Comment }
      .map { |resource| resource.resource_name.route_key }

    expect(records.keys + [ "dashboards" ]).to match_array(registered_pages)
  end

  it "loads the dashboard" do
    get admin_root_path

    expect(response).to have_http_status(:ok)
  end

  records.each do |route_key, create_record|
    context route_key do
      let!(:record) { instance_exec(&create_record) }

      it "loads the index with a record" do
        get public_send("admin_#{route_key}_path")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(record.id)
      end

      it "loads the show page" do
        get public_send("admin_#{route_key.singularize}_path", record)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(record.id)
      end
    end
  end
end
