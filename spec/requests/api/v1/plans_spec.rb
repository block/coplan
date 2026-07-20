require "rails_helper"

RSpec.describe "Api::V1::Plans", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:carol) { create(:coplan_user, :admin) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:carol_token) { create(:api_token, user: carol, raw_token: "test-token-carol") }
  let(:revoked_token) { create(:api_token, :revoked, user: alice, raw_token: "test-token-revoked") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:plan) { create(:plan, :considering, created_by_user: alice, title: "Acme Roadmap") }

  before do
    alice_token # ensure token exists
  end

  it "index returns plans" do
    plan # trigger creation
    get api_v1_plans_path, headers: headers
    expect(response).to have_http_status(:success)
    plans = JSON.parse(response.body)
    expect(plans.any? { |p| p["title"] == "Acme Roadmap" }).to be true
  end

  it "index shows all non-brainstorm plans to any authenticated user" do
    plan # trigger creation
    carol_token # ensure token exists
    get api_v1_plans_path, headers: { "Authorization" => "Bearer test-token-carol" }
    expect(response).to have_http_status(:success)
    plans = JSON.parse(response.body)
    expect(plans.any? { |p| p["title"] == "Acme Roadmap" }).to be true
  end

  it "index requires auth" do
    get api_v1_plans_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "index with revoked token" do
    revoked_token # ensure token exists
    get api_v1_plans_path, headers: { "Authorization" => "Bearer test-token-revoked" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "show returns plan" do
    get api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:success)
    body = JSON.parse(response.body)
    expect(body["title"]).to eq("Acme Roadmap")
    expect(body["current_content"]).to be_present
  end

  it "show returns plan for any authenticated user" do
    carol_token # ensure token exists
    get api_v1_plan_path(plan), headers: { "Authorization" => "Bearer test-token-carol" }
    expect(response).to have_http_status(:success)
  end

  it "create creates new plan" do
    expect {
      post api_v1_plans_path, params: { title: "API Plan", content: "# API Plan\n\nCreated via API." }, headers: headers, as: :json
    }.to change(CoPlan::Plan, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["title"]).to eq("API Plan")
    expect(body["current_revision"]).to eq(1)
  end

  it "create with plan_type by name" do
    plan_type = create(:plan_type, name: "design-doc")
    post api_v1_plans_path, params: { title: "Typed Plan", content: "# Typed", plan_type: "design-doc" }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["plan_type_id"]).to eq(plan_type.id)
    expect(body["plan_type_name"]).to eq("design-doc")
  end

  it "create with unknown plan_type returns 422 with available types" do
    create(:plan_type, name: "design-doc")
    create(:plan_type, name: "rfc")
    post api_v1_plans_path, params: { title: "Bad Type", plan_type: "nope" }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    body = JSON.parse(response.body)
    expect(body["error"]).to include("nope")
    expect(body["error"]).to include("design-doc")
    expect(body["error"]).to include("rfc")
  end

  it "create without title fails" do
    post api_v1_plans_path, params: { content: "no title" }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  describe "PATCH /api/v1/plans/:id" do
    it "updates plan title" do
      patch api_v1_plan_path(plan), params: { title: "New Title" }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["title"]).to eq("New Title")
      expect(plan.reload.title).to eq("New Title")
    end

    it "maps legacy status writes onto visibility/archived" do
      draft = create(:plan, :draft, created_by_user: alice)
      patch api_v1_plan_path(draft), params: { status: "developing" }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["visibility"]).to eq("published")
      # Legacy echo: active published plans read back as "considering".
      expect(body["status"]).to eq("considering")
      expect(draft.reload.published?).to be(true)
    end

    it "updates plan tags" do
      patch api_v1_plan_path(plan), params: { tags: [ "infra", "api" ] }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["tags"]).to match_array([ "infra", "api" ])
      expect(plan.reload.tag_names).to match_array([ "infra", "api" ])
    end

    it "updates multiple fields at once" do
      patch api_v1_plan_path(plan), params: { title: "Updated", archived: true, tags: [ "v2" ] }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["title"]).to eq("Updated")
      expect(body["archived"]).to be(true)
      expect(body["tags"]).to eq([ "v2" ])
    end

    it "leaves unchanged fields alone" do
      original_title = plan.title
      patch api_v1_plan_path(plan), params: { tags: [ "new-tag" ] }, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      expect(plan.reload.title).to eq(original_title)
    end

    it "rejects invalid status" do
      patch api_v1_plan_path(plan), params: { status: "invalid" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 403 for non-author (carol)" do
      carol_token
      patch api_v1_plan_path(plan), params: { title: "Hacked" }, headers: { "Authorization" => "Bearer test-token-carol" }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 for non-author" do
      bob = create(:coplan_user)
      bob_token = create(:api_token, user: bob, raw_token: "test-token-bob")
      patch api_v1_plan_path(plan), params: { title: "Nope" }, headers: { "Authorization" => "Bearer test-token-bob" }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "requires auth" do
      patch api_v1_plan_path(plan), params: { title: "No Auth" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    describe "folder assignment (placements in the caller's library)" do
      def alice_placement
        alice.library.placements.find_by(plan_id: plan.id)
      end

      it "shelves the plan in a folder by folder_id and logs an event" do
        folder = create(:folder, name: "Infra", created_by_user: alice)
        expect {
          patch api_v1_plan_path(plan), params: { folder_id: folder.id }, headers: headers, as: :json
        }.to change(CoPlan::PlanEvent, :count).by(1)
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)
        expect(body["folder_id"]).to eq(folder.id)
        expect(body["folder_path"]).to eq("Infra")
        expect(alice_placement.folder).to eq(folder)

        event = CoPlan::PlanEvent.order(:created_at).last
        expect(event.event_type).to eq("moved_to_folder")
        expect(event.field).to eq("folder")
        expect(event.before_value).to be_nil
        expect(event.after_value).to eq("Infra")
      end

      it "finds-or-creates the hierarchy in the caller's library via folder_path" do
        expect {
          patch api_v1_plan_path(plan), params: { folder_path: "Team EBT/Q3" }, headers: headers, as: :json
        }.to change(CoPlan::Folder, :count).by(2)
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)["folder_path"]).to eq("Team EBT/Q3")
        expect(alice_placement.folder.path).to eq("Team EBT/Q3")
        expect(alice_placement.folder.library).to eq(alice.library)
      end

      it "reuses existing folders via folder_path" do
        root = create(:folder, name: "Team EBT", created_by_user: alice)
        sub = create(:folder, name: "Q3", parent: root, created_by_user: alice, library: root.library)
        expect {
          patch api_v1_plan_path(plan), params: { folder_path: "Team EBT/Q3" }, headers: headers, as: :json
        }.not_to change(CoPlan::Folder, :count)
        expect(alice_placement.folder).to eq(sub)
      end

      it "rejects a folder_id from someone else's library" do
        other_folder = create(:folder, name: "Not Yours")
        patch api_v1_plan_path(plan), params: { folder_id: other_folder.id }, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(alice_placement).to be_nil
      end

      it "takes the plan off the shelf with a blank folder_id" do
        folder = create(:folder, name: "Infra", created_by_user: alice)
        CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: alice)

        patch api_v1_plan_path(plan), params: { folder_id: "" }, headers: headers, as: :json
        expect(response).to have_http_status(:success)
        expect(alice_placement).to be_nil

        event = CoPlan::PlanEvent.order(:created_at).last
        expect(event.event_type).to eq("moved_to_folder")
        expect(event.before_value).to eq("Infra")
        expect(event.after_value).to be_nil
      end

      it "rejects an unknown folder_id" do
        patch api_v1_plan_path(plan), params: { folder_id: "nope" }, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to include("Unknown folder_id")
        expect(alice_placement).to be_nil
      end

      it "rejects a folder_path deeper than the max depth" do
        patch api_v1_plan_path(plan), params: { folder_path: "A/B/C/D" }, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "does not log an event when the folder is unchanged" do
        folder = create(:folder, name: "Infra", created_by_user: alice)
        CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: alice)
        expect {
          patch api_v1_plan_path(plan), params: { folder_id: folder.id }, headers: headers, as: :json
        }.not_to change(CoPlan::PlanEvent, :count)
      end

      it "rolls back folder_path creation when the rest of the update fails" do
        patch api_v1_plan_path(plan),
          params: { folder_path: "New Team/Sub", status: "bogus" },
          headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(alice_placement).to be_nil
        # The invalid status aborted the whole update — no orphaned
        # folders left behind for a move that never happened.
        expect(CoPlan::Folder.count).to eq(0)
      end
    end
  end

  it "versions returns version list" do
    get versions_api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:success)
    versions = JSON.parse(response.body)
    expect(versions.any? { |v| v["revision"] == 1 }).to be true
  end

  it "comments returns thread list with anchor_text" do
    thread = create(:comment_thread, :with_anchor, plan: plan,
      plan_version: plan.current_plan_version, created_by_user: alice, anchor_text: "original roadmap text")
    get comments_api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:success)
    threads = JSON.parse(response.body)
    expect(threads).to be_a(Array)
    matching = threads.find { |t| t["id"] == thread.id }
    expect(matching["anchor_text"]).to eq("original roadmap text")
  end

  describe "GET /api/v1/plans/:id/snapshot" do
    it "returns plan with all nested data in one response" do
      thread = create(:comment_thread, :with_positioned_anchor, plan: plan,
        plan_version: plan.current_plan_version, created_by_user: alice)
      comment = create(:comment, comment_thread: thread, body_markdown: "Snapshot comment")
      ref = create(:reference, plan: plan, url: "https://example.com/snapshot", title: "Snapshot Ref")
      collaborator = create(:plan_collaborator, plan: plan, user: carol, role: "reviewer")

      get snapshot_api_v1_plan_path(plan), headers: headers

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)

      # Plan metadata — created_by preserved as string, created_by_user added as object
      expect(body["id"]).to eq(plan.id)
      expect(body["title"]).to eq("Acme Roadmap")
      expect(body["current_content"]).to be_present
      expect(body["current_revision"]).to be_present
      expect(body["created_by"]).to eq(alice.name)
      expect(body["created_by_user"]).to eq({ "id" => alice.id, "name" => alice.name })

      # Comment threads with anchor_occurrence and structured created_by_user
      expect(body["comment_threads"]).to be_a(Array)
      matching_thread = body["comment_threads"].find { |t| t["id"] == thread.id }
      expect(matching_thread["anchor_text"]).to eq("some anchor text")
      expect(matching_thread).to have_key("anchor_occurrence")
      expect(matching_thread["created_by"]).to eq(alice.name)
      expect(matching_thread["created_by_user"]).to eq({ "id" => alice.id, "name" => alice.name })
      expect(matching_thread["comments"]).to be_a(Array)
      matching_comment = matching_thread["comments"].find { |c| c["body_markdown"] == "Snapshot comment" }
      expect(matching_comment).to be_present
      expect(matching_comment).to have_key("author_id")

      # References
      expect(body["references"]).to be_a(Array)
      expect(body["references"].any? { |r| r["url"] == "https://example.com/snapshot" }).to be true

      # Collaborators with structured user
      expect(body["collaborators"]).to be_a(Array)
      matching_collab = body["collaborators"].find { |c| c.dig("user", "id") == carol.id }
      expect(matching_collab["role"]).to eq("reviewer")
      expect(matching_collab["user"]["name"]).to eq(carol.name)
    end

    it "requires auth" do
      get snapshot_api_v1_plan_path(plan)
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for nonexistent plan" do
      get snapshot_api_v1_plan_path(id: "nonexistent"), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
