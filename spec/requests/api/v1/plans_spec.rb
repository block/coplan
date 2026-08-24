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

  # Counts the index's queries against one set of tables rather than all of
  # them: each preload spec below is about a single field, and a total would
  # fail for an unrelated query and then get bumped to whatever number made
  # it pass. The assertion is a shape — the cost doesn't follow the list —
  # not a magic number.
  def index_queries_touching(table_pattern)
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:name].to_s =~ /SCHEMA|TRANSACTION/
      count += 1 if payload[:sql].to_s.match?(table_pattern)
    end
    get api_v1_plans_path, headers: headers
    ActiveSupport::Notifications.unsubscribe(sub)
    expect(response).to have_http_status(:success)
    count
  end

  # Every row carries `url` and `folder_path`, and both want the plan's
  # whole location — the folder's ancestors, and the library for its handle.
  # Reached through the associations that's several queries per plan on a
  # list agents page through, so the location is preloaded.
  it "reads each plan's location once for the whole index, not once per plan" do
    folder = create(:folder, name: "LiveOrder", created_by_user: alice)
    nested = create(:folder, name: "Q3", parent: folder, created_by_user: alice)

    3.times { |i| CoPlan::Plans::Place.call(plan: create(:plan, :considering, created_by_user: alice, title: "Roadmap #{i}"), folder: nested, actor: alice) }
    few = index_queries_touching(/coplan_(plan_placements|folders|libraries)/)

    27.times { |i| CoPlan::Plans::Place.call(plan: create(:plan, :considering, created_by_user: alice, title: "Later #{i}"), folder: folder, actor: alice) }
    many = index_queries_touching(/coplan_(plan_placements|folders|libraries)/)

    body = JSON.parse(response.body)
    expect(body.size).to eq(30)
    # The preload has to be right, not just cheap — thirty distinct addresses,
    # each naming the folder the plan is actually in.
    expect(body.map { |p| p["url"] }.uniq.size).to eq(30)
    expect(body.map { |p| p["folder_path"] }.tally).to eq("LiveOrder/Q3" => 3, "LiveOrder" => 27)
    expect(many).to eq(few)
  end

  # Same story for `tags`: `tag_names` reads them straight off the plan when
  # they're loaded, and queries for them when they aren't, so leaving them
  # out of the index's eager loads costs a query a row.
  it "reads every plan's tags once for the whole index, not once per plan" do
    tag_plans = lambda do |count, prefix|
      count.times do |i|
        plan = create(:plan, :considering, created_by_user: alice, title: "#{prefix} #{i}")
        plan.tag_names = [ "roadmap", "#{prefix.downcase}-#{i}" ]
      end
    end

    tag_plans.call(3, "Roadmap")
    few = index_queries_touching(/coplan_(tags|plan_tags)/)

    tag_plans.call(27, "Later")
    many = index_queries_touching(/coplan_(tags|plan_tags)/)

    body = JSON.parse(response.body)
    expect(body.size).to eq(30)
    # Cheap and correct: each plan still gets its own two tags, not another's.
    expected = (0...3).map { |i| [ "roadmap", "roadmap-#{i}" ] } +
      (0...27).map { |i| [ "later-#{i}", "roadmap" ] }
    expect(body.map { |p| p["tags"].sort }.sort).to eq(expected.map(&:sort).sort)
    expect(many).to eq(few)
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
      post api_v1_plans_path, params: { title: "API Plan", content: "# API Plan\n\nCreated via API.", agent_name: "Claude" }, headers: headers, as: :json
    }.to change(CoPlan::Plan, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["title"]).to eq("API Plan")
    expect(body["current_revision"]).to eq(1)

    version = CoPlan::Plan.find(body.fetch("id")).current_plan_version
    expect(version).to have_attributes(
      actor_type: "local_agent",
      actor_id: alice.id,
      agent_name: "Claude",
      api_token_id: alice_token.id
    )
  end

  it "create without plan_type files the plan under the General catch-all" do
    post api_v1_plans_path, params: { title: "Untyped Plan", content: "# Untyped" }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["plan_type_name"]).to eq("General")
  end

  it "create with plan_type by name" do
    plan_type = create(:plan_type, name: "design-doc")
    post api_v1_plans_path, params: { title: "Typed Plan", content: "# Typed", plan_type: "design-doc" }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["plan_type_id"]).to eq(plan_type.id)
    expect(body["plan_type_name"]).to eq("design-doc")
  end

  # The documented /agent-instructions payload sends "general" while the
  # built-in type is stored as "General" — resolution must not depend on the
  # database's collation being case-insensitive (MySQL's usually is,
  # PostgreSQL's isn't).
  it "create resolves plan_type case-insensitively" do
    plan_type = create(:plan_type, name: "General")
    post api_v1_plans_path, params: { title: "My Plan", content: "# My Plan\n\nContent here.", plan_type: "general" }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["plan_type_id"]).to eq(plan_type.id)
    expect(body["plan_type_name"]).to eq("General")
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

  describe "filing on create" do
    it "files the plan via folder_path, creating the hierarchy in the caller's library" do
      post api_v1_plans_path, params: { title: "Filed Plan", content: "# Filed", folder_path: "Team EBT/Q3" }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["folder_path"]).to eq("Team EBT/Q3")

      placement = alice.library.placements.find_by(plan_id: body.fetch("id"))
      expect(placement.folder.path).to eq("Team EBT/Q3")
      expect(alice.library.folders.count).to eq(2)
    end

    it "files the plan via folder_id" do
      folder = create(:folder, name: "Infra", created_by_user: alice)
      post api_v1_plans_path, params: { title: "Filed Plan", content: "# Filed", folder_id: folder.id }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["folder_id"]).to eq(folder.id)
    end

    it "records the filing in the library audit log with agent attribution" do
      post api_v1_plans_path, params: { title: "Filed Plan", content: "# Filed", folder_path: "Infra", agent_name: "Claude" }, headers: headers, as: :json
      expect(response).to have_http_status(:created)

      event = alice.library.library_events.find_by(event_type: "plan_filed")
      expect(event).to be_present
      expect(event.actor_type).to eq("local_agent")
      expect(event.agent_name).to eq("Claude")
    end

    it "rolls back the whole create when the folder_id is unknown" do
      expect {
        post api_v1_plans_path, params: { title: "Doomed Plan", content: "# Doomed", folder_id: "nope" }, headers: headers, as: :json
      }.not_to change(CoPlan::Plan, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("Unknown folder_id")
    end

    it "does not emit a plan_created analytics event for a rolled-back create" do
      events = capture_analytics_events do
        post api_v1_plans_path, params: { title: "Doomed Plan", content: "# Doomed", folder_id: "nope" }, headers: headers, as: :json
      end
      expect(response).to have_http_status(:unprocessable_content)
      expect(events.select { |name, _| name == "plan_created" }).to be_empty
    end

    it "emits plan_created exactly once for a successful filed create" do
      events = capture_analytics_events do
        post api_v1_plans_path, params: { title: "Filed Plan", content: "# Filed", folder_path: "Infra" }, headers: headers, as: :json
      end
      expect(response).to have_http_status(:created)
      expect(events.select { |name, _| name == "plan_created" }.length).to eq(1)
    end
  end

  describe "retyping via update" do
    let!(:scratchpad) { create(:plan_type, name: "Scratchpad", default_tags: []) }
    let!(:design) { create(:plan_type, name: "Engineering Design", default_tags: [ "design" ]) }

    it "changes the plan's type, adopts default_tags, and logs events" do
      typed_plan = create(:plan, :considering, created_by_user: alice, plan_type: scratchpad)

      patch api_v1_plan_path(typed_plan), params: { plan_type: "engineering design" }, headers: headers, as: :json

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["plan_type_name"]).to eq("Engineering Design")
      expect(body["tags"]).to include("design")

      type_event = typed_plan.plan_events.find_by(event_type: "plan_type_changed")
      expect(type_event.before_value).to eq("Scratchpad")
      expect(type_event.after_value).to eq("Engineering Design")
      expect(typed_plan.plan_events.where(event_type: "tag_added", after_value: "design")).to exist
    end

    it "keeps existing tags on retype" do
      typed_plan = create(:plan, :considering, created_by_user: alice, plan_type: scratchpad)
      typed_plan.tag_names = [ "pricing" ]

      patch api_v1_plan_path(typed_plan), params: { plan_type: "Engineering Design" }, headers: headers, as: :json

      expect(JSON.parse(response.body)["tags"]).to match_array([ "pricing", "design" ])
    end

    it "is a no-op event-wise when the type is unchanged" do
      typed_plan = create(:plan, :considering, created_by_user: alice, plan_type: design)

      patch api_v1_plan_path(typed_plan), params: { plan_type: "Engineering Design" }, headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(typed_plan.plan_events.where(event_type: "plan_type_changed")).not_to exist
    end

    it "rejects an unknown plan_type with the valid names" do
      typed_plan = create(:plan, :considering, created_by_user: alice, plan_type: scratchpad)

      patch api_v1_plan_path(typed_plan), params: { plan_type: "nope" }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("Scratchpad")
      expect(typed_plan.reload.plan_type).to eq(scratchpad)
    end

    it "rejects a blank plan_type — every plan has a type" do
      typed_plan = create(:plan, :considering, created_by_user: alice, plan_type: scratchpad)

      patch api_v1_plan_path(typed_plan), params: { plan_type: "" }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("cannot be blank")
    end
  end

  describe "tags on create" do
    it "applies the plan type's default_tags" do
      create(:plan_type, name: "design-doc", default_tags: [ "design", "architecture" ])
      post api_v1_plans_path, params: { title: "Tagged Plan", content: "# Tagged", plan_type: "design-doc" }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["tags"]).to match_array([ "design", "architecture" ])
    end

    it "merges explicit tags with the type's default_tags" do
      create(:plan_type, name: "design-doc", default_tags: [ "design" ])
      post api_v1_plans_path, params: { title: "Tagged Plan", content: "# Tagged", plan_type: "design-doc", tags: [ "pricing", "design" ] }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["tags"]).to match_array([ "design", "pricing" ])
    end

    it "accepts explicit tags without a plan_type" do
      post api_v1_plans_path, params: { title: "Tagged Plan", content: "# Tagged", tags: [ "pricing" ] }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["tags"]).to eq([ "pricing" ])
    end
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
      plan_version: plan.current_plan_version, created_by_user: alice)
    get comments_api_v1_plan_path(plan), headers: headers
    expect(response).to have_http_status(:success)
    threads = JSON.parse(response.body)
    expect(threads).to be_a(Array)
    matching = threads.find { |t| t["id"] == thread.id }
    expect(matching["anchor_text"]).to eq("Some content here")
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

  describe "GET /api/v1/plans/:id/locations" do
    # Still an array — a plan has one location or none, and clients
    # already iterate it.
    it "returns the one library the plan is filed in" do
      published = create(:plan, :considering, created_by_user: alice)
      alice_folder = create(:folder, name: "Mine", description: "Alice's shelf", created_by_user: alice)
      CoPlan::Plans::Place.call(plan: published, folder: alice_folder, actor: alice)

      get locations_api_v1_plan_path(published), headers: headers
      expect(response).to have_http_status(:success)
      location = JSON.parse(response.body).sole

      expect(location["library_id"]).to eq(alice.library.id)
      expect(location["folder_path"]).to eq("Mine")
      expect(location["folder_description"]).to eq("Alice's shelf")
      expect(location["writable"]).to be(true)
      expect(location["owner"]["name"]).to eq(alice.name)
      expect(location["placed_by"]).to eq(alice.name)
    end

    it "returns nothing for an unfiled plan" do
      get locations_api_v1_plan_path(create(:plan, :considering, created_by_user: alice)),
        headers: headers
      expect(JSON.parse(response.body)).to be_empty
    end

    it "requires auth" do
      get locations_api_v1_plan_path(plan)
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
