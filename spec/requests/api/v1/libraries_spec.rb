require "rails_helper"

RSpec.describe "Api::V1::Libraries", type: :request do
  let(:alice) { create(:coplan_user) }
  let(:bob) { create(:coplan_user) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:bob_token) { create(:api_token, user: bob, raw_token: "test-token-bob") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:json_headers) { headers.merge("Content-Type" => "application/json") }
  let(:bob_headers) { { "Authorization" => "Bearer test-token-bob" } }

  before do
    alice_token
    bob_token
  end

  describe "GET /api/v1/libraries" do
    it "lists libraries with ownership and writability" do
      alice.library
      bob.library

      get api_v1_libraries_path, headers: headers
      expect(response).to have_http_status(:success)
      libraries = JSON.parse(response.body)
      mine = libraries.find { |l| l["id"] == alice.library.id }
      other = libraries.find { |l| l["id"] == bob.library.id }
      expect(mine["writable"]).to be(true)
      expect(mine["owner"]["name"]).to eq(alice.name)
      expect(other["writable"]).to be(false)
    end
  end

  describe "GET /api/v1/library (overview)" do
    it "returns the folder tree with descriptions, paths, and subtree counts" do
      root = create(:folder, name: "Team EBT", description: "EBT rollout work", created_by_user: alice)
      sub = create(:folder, name: "Q3", parent: root, created_by_user: alice)
      plan = create(:plan, :published, created_by_user: alice, tags: [ create(:tag, name: "pricing") ])
      CoPlan::Plans::Place.call(plan: plan, folder: sub, actor: alice)

      get "/api/v1/library", headers: headers
      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json["id"]).to eq(alice.library.id)
      expect(json["writable"]).to be(true)

      root_json = json["folders"].find { |f| f["id"] == root.id }
      sub_json = json["folders"].find { |f| f["id"] == sub.id }
      expect(root_json["description"]).to eq("EBT rollout work")
      expect(root_json["plans_count"]).to eq(0)
      expect(root_json["total_plans_count"]).to eq(1)
      expect(sub_json["path"]).to eq("Team EBT/Q3")
      expect(sub_json["plans_count"]).to eq(1)

      expect(json["top_tags"]).to include({ "name" => "pricing", "plans_count" => 1 })
      expect(json["organize_instructions_url"]).to include("agent-instructions/organizing")
      expect(json).to have_key("unfiled_count")
      expect(json).to have_key("recent_activity")
    end

    it "counts unfiled plans (own active plans without a placement)" do
      create(:plan, :published, created_by_user: alice)

      get "/api/v1/library", headers: headers
      expect(JSON.parse(response.body)["unfiled_count"]).to eq(1)
    end

    it "hides owner-only fields when browsing someone else's library" do
      get api_v1_library_path(bob.library), headers: headers
      json = JSON.parse(response.body)
      expect(json["writable"]).to be(false)
      expect(json).not_to have_key("unfiled_count")
      expect(json).not_to have_key("recent_activity")
    end

    it "404s for unknown libraries" do
      get api_v1_library_path("nope"), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/library/contents" do
    it "returns one row per placement with summary, tags, and location" do
      folder = create(:folder, name: "Infra", created_by_user: alice)
      plan = create(:plan, :published, created_by_user: bob, title: "Zonal failover")
      plan.update_columns(summary: "A plan about failover.")
      plan.tag_names = [ "infra" ]
      plan.save!
      CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: alice)

      get "/api/v1/library/contents", headers: headers
      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)
      expect(json["count"]).to eq(1)
      row = json["items"].first
      expect(row["title"]).to eq("Zonal failover")
      expect(row["summary"]).to eq("A plan about failover.")
      expect(row["tags"]).to eq([ "infra" ])
      expect(row["folder_path"]).to eq("Infra")
      expect(row["author"]).to eq(bob.name)
    end

    it "filters by folder subtree with recursive=true" do
      root = create(:folder, name: "A", created_by_user: alice)
      sub = create(:folder, name: "B", parent: root, created_by_user: alice)
      other = create(:folder, name: "C", created_by_user: alice)
      in_sub = create(:plan, :published, created_by_user: alice)
      in_other = create(:plan, :published, created_by_user: alice)
      CoPlan::Plans::Place.call(plan: in_sub, folder: sub, actor: alice)
      CoPlan::Plans::Place.call(plan: in_other, folder: other, actor: alice)

      get "/api/v1/library/contents", params: { folder_path: "A", recursive: "true" }, headers: headers
      ids = JSON.parse(response.body)["items"].map { |i| i["plan_id"] }
      expect(ids).to eq([ in_sub.id ])
    end

    it "filters by tag" do
      folder = create(:folder, created_by_user: alice)
      tagged = create(:plan, :published, created_by_user: alice)
      tagged.tag_names = [ "pricing" ]
      tagged.save!
      untagged = create(:plan, :published, created_by_user: alice)
      CoPlan::Plans::Place.call(plan: tagged, folder: folder, actor: alice)
      CoPlan::Plans::Place.call(plan: untagged, folder: folder, actor: alice)

      get "/api/v1/library/contents", params: { tag: "pricing" }, headers: headers
      ids = JSON.parse(response.body)["items"].map { |i| i["plan_id"] }
      expect(ids).to eq([ tagged.id ])
    end

    it "lists unfiled plans with unfiled=true, own library only" do
      create(:plan, :published, created_by_user: alice, title: "Loose plan")

      get "/api/v1/library/contents", params: { unfiled: "true" }, headers: headers
      json = JSON.parse(response.body)
      expect(json["items"].map { |i| i["title"] }).to eq([ "Loose plan" ])
      expect(json["items"].first["folder_path"]).to be_nil

      get contents_api_v1_library_path(bob.library), params: { unfiled: "true" }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "hides other users' drafts" do
      folder = create(:folder, created_by_user: alice)
      draft = create(:plan, :draft, created_by_user: alice)
      CoPlan::Plans::Place.call(plan: draft, folder: folder, actor: alice)

      get contents_api_v1_library_path(alice.library), headers: bob_headers
      expect(JSON.parse(response.body)["count"]).to eq(0)
    end
  end

  describe "POST /api/v1/library/organize" do
    it "applies a batch of folder and move operations, auditing each" do
      plan = create(:plan, :published, created_by_user: alice, title: "Pricing plan")

      post "/api/v1/library/organize",
        params: {
          operations: [
            { op: "create_folder", path: "Archive/2025", description: "Old work" },
            { op: "move", plan_id: plan.id, folder_path: "Archive/2025" }
          ]
        }.to_json,
        headers: json_headers

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)
      expect(json["applied"]).to be(true)
      expect(json["ok_count"]).to eq(2)
      expect(json["error_count"]).to eq(0)

      placement = alice.library.placements.find_by(plan_id: plan.id)
      expect(placement.folder.path).to eq("Archive/2025")
      expect(placement.folder.parent.name).to eq("Archive")
      expect(CoPlan::Folder.find_by(name: "2025").description).to eq("Old work")

      events = alice.library.library_events.order(:created_at)
      expect(events.map(&:event_type)).to include("folder_created", "folder_described", "plan_filed")
      # Token auth means the agent gets attributed, not a human.
      expect(events.map(&:actor_type).uniq).to eq([ "local_agent" ])
      filed = events.find_by(event_type: "plan_filed")
      expect(filed.after_value).to eq("Archive/2025")
      expect(filed.metadata["plan_title"]).to eq("Pricing plan")
    end

    it "reports per-op errors without aborting the batch" do
      post "/api/v1/library/organize",
        params: {
          operations: [
            { op: "delete_folder", folder_path: "Does Not Exist" },
            { op: "create_folder", path: "Real" }
          ]
        }.to_json,
        headers: json_headers

      json = JSON.parse(response.body)
      expect(json["error_count"]).to eq(1)
      expect(json["ok_count"]).to eq(1)
      expect(json["results"][0]["status"]).to eq("error")
      expect(alice.library.folders.exists?(name: "Real")).to be(true)
    end

    it "rolls everything back with dry_run while reporting what would happen" do
      plan = create(:plan, :published, created_by_user: alice)

      post "/api/v1/library/organize",
        params: {
          dry_run: true,
          operations: [ { op: "move", plan_id: plan.id, folder_path: "Proposed/Structure" } ]
        }.to_json,
        headers: json_headers

      json = JSON.parse(response.body)
      expect(json["dry_run"]).to be(true)
      expect(json["ok_count"]).to eq(1)
      expect(json["results"][0]["path"]).to eq("Proposed/Structure")

      expect(alice.library.folders.count).to eq(0)
      expect(alice.library.placements.count).to eq(0)
      expect(alice.library.library_events.count).to eq(0)
    end

    it "moves every tagged plan on the shelf with move_by_tag" do
      inbox = create(:folder, name: "Inbox", created_by_user: alice)
      tagged1 = create(:plan, :published, created_by_user: alice)
      tagged2 = create(:plan, :published, created_by_user: alice)
      untagged = create(:plan, :published, created_by_user: alice)
      [ tagged1, tagged2 ].each do |plan|
        plan.tag_names = [ "pricing" ]
        plan.save!
      end
      [ tagged1, tagged2, untagged ].each do |plan|
        CoPlan::Plans::Place.call(plan: plan, folder: inbox, actor: alice)
      end

      post "/api/v1/library/organize",
        params: { operations: [ { op: "move_by_tag", tag: "pricing", folder_path: "Pricing" } ] }.to_json,
        headers: json_headers

      json = JSON.parse(response.body)
      expect(json["results"][0]["moved_count"]).to eq(2)
      pricing = CoPlan::Folder.find_by(name: "Pricing", library: alice.library)
      expect(pricing.placements.map(&:plan_id)).to match_array([ tagged1.id, tagged2.id ])
      expect(inbox.placements.map(&:plan_id)).to eq([ untagged.id ])
    end

    it "moves a batch of plans in one grouped op with move_many" do
      plans = create_list(:plan, 3, :published, created_by_user: alice)

      post "/api/v1/library/organize",
        params: {
          operations: [
            { op: "move_many", plan_ids: plans.map(&:id) + [ "missing-id" ], folder_path: "Sorted" }
          ]
        }.to_json,
        headers: json_headers

      json = JSON.parse(response.body)
      result = json["results"][0]
      expect(result["status"]).to eq("ok")
      expect(result["moved_count"]).to eq(3)
      expect(result["moved"].map { |m| m["plan_id"] }).to match_array(plans.map(&:id))
      expect(result["failed"]).to eq([ { "plan_id" => "missing-id", "error" => "Plan not found" } ])
      sorted = CoPlan::Folder.find_by(name: "Sorted", library: alice.library)
      expect(sorted.placements.count).to eq(3)
    end

    it "rejects a move_many exceeding the per-op plan cap" do
      too_many = (CoPlan::Libraries::Organize::MAX_PLANS_PER_MOVE + 1).times.map { |i| "id-#{i}" }

      post "/api/v1/library/organize",
        params: { operations: [ { op: "move_many", plan_ids: too_many, folder_path: "X" } ] }.to_json,
        headers: json_headers

      json = JSON.parse(response.body)
      expect(json["results"][0]["status"]).to eq("error")
      expect(json["results"][0]["error"]).to match(/max #{CoPlan::Libraries::Organize::MAX_PLANS_PER_MOVE}/)
      expect(alice.library.folders.find_by(name: "X")).to be_nil
    end

    it "groups every audit event under the returned run_id with the token's label" do
      plan = create(:plan, :published, created_by_user: alice)

      post "/api/v1/library/organize",
        params: {
          operations: [
            { op: "create_folder", path: "Grouped" },
            { op: "move", plan_id: plan.id, folder_path: "Grouped" }
          ]
        }.to_json,
        headers: json_headers

      run_id = JSON.parse(response.body)["run_id"]
      expect(run_id).to be_present

      events = alice.library.library_events
      expect(events.pluck(:run_id).uniq).to eq([ run_id ])
      expect(events.map { |e| e.metadata["actor_label"] }.uniq).to eq([ alice_token.name ])

      get "/api/v1/library/events", params: { run_id: run_id }, headers: headers
      listed = JSON.parse(response.body)
      expect(listed.size).to eq(events.count)
      expect(listed.map { |e| e["run_id"] }.uniq).to eq([ run_id ])
      expect(listed.first["actor_label"]).to eq(alice_token.name)
    end

    it "moves a plan between libraries with from_library_id" do
      # Simulate a future team library by making bob's library writable to
      # alice — writable_by? is the only gate Organize consults.
      allow_any_instance_of(CoPlan::Library).to receive(:writable_by?).and_return(true)
      plan = create(:plan, :published, created_by_user: alice)
      source_folder = create(:folder, name: "Mine", created_by_user: alice)
      CoPlan::Plans::Place.call(plan: plan, folder: source_folder, actor: alice)

      post organize_api_v1_library_path(bob.library),
        params: {
          operations: [
            { op: "move", plan_id: plan.id, folder_path: "Shared", from_library_id: alice.library.id }
          ]
        }.to_json,
        headers: json_headers

      json = JSON.parse(response.body)
      expect(json["ok_count"]).to eq(1)
      expect(alice.library.placements.count).to eq(0)
      expect(bob.library.placements.first.folder.name).to eq("Shared")
    end

    it "refuses to organize a library you cannot write" do
      post organize_api_v1_library_path(bob.library),
        params: { operations: [ { op: "create_folder", path: "Nope" } ] }.to_json,
        headers: json_headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /api/v1/library/events" do
    it "returns the audit log, newest first, flagging agent actors" do
      folder = create(:folder, name: "Infra", created_by_user: alice)
      plan = create(:plan, :published, created_by_user: alice, title: "Audited plan")
      CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: alice, actor_type: "local_agent")
      CoPlan::Plans::Place.call(plan: plan, folder: nil, actor: alice)

      get "/api/v1/library/events", headers: headers
      expect(response).to have_http_status(:success)
      events = JSON.parse(response.body)
      expect(events.map { |e| e["event_type"] }).to eq([ "plan_removed", "plan_filed" ])

      filed = events.last
      expect(filed["agent"]).to be(true)
      expect(filed["actor_type"]).to eq("local_agent")
      expect(filed["actor"]["name"]).to eq(alice.name)
      expect(filed["plan_title"]).to eq("Audited plan")
      expect(filed["after"]).to eq("Infra")

      removed = events.first
      expect(removed["agent"]).to be(false)
      expect(removed["before"]).to eq("Infra")
      expect(removed["after"]).to be_nil
    end

    it "filters by event_type and is owner-only" do
      folder = create(:folder, created_by_user: alice)
      plan = create(:plan, :published, created_by_user: alice)
      CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: alice)

      get "/api/v1/library/events", params: { event_type: "plan_filed" }, headers: headers
      expect(JSON.parse(response.body).map { |e| e["event_type"] }.uniq).to eq([ "plan_filed" ])

      get events_api_v1_library_path(alice.library), headers: bob_headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
