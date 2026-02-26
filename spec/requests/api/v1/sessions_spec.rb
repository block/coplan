require "rails_helper"

RSpec.describe "Api::V1::Sessions", type: :request do
  let(:alice) { create(:user, :admin) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }

  before do
    alice_token # ensure token exists
  end

  describe "POST /api/v1/plans/:plan_id/sessions" do
    it "creates a session with correct defaults" do
      expect {
        post api_v1_plan_sessions_path(plan), headers: headers, as: :json
      }.to change(CoPlan::EditSession, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["plan_id"]).to eq(plan.id)
      expect(body["status"]).to eq("open")
      expect(body["actor_type"]).to eq("local_agent")
      expect(body["base_revision"]).to eq(plan.current_revision)
      expect(body["expires_at"]).to be_present
      expect(body["id"]).to be_present
    end

    it "requires authentication" do
      post api_v1_plan_sessions_path(plan), as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/plans/:plan_id/sessions/:id" do
    it "returns session details" do
      session = create(:edit_session, plan: plan, actor_id: alice_token.id)

      get api_v1_plan_session_path(plan, session), headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["id"]).to eq(session.id)
      expect(body["status"]).to eq("open")
      expect(body["operations_count"]).to eq(0)
      expect(body["has_draft"]).to eq(false)
    end

    it "returns 404 for unknown session" do
      get api_v1_plan_session_path(plan, "nonexistent-id"), headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/plans/:plan_id/sessions/:id/commit" do
    it "commits with operations and creates version" do
      session = create(:edit_session, plan: plan, actor_id: alice_token.id)
      # Apply an operation to the session first
      current_content = plan.current_content
      result = CoPlan::Plans::ApplyOperations.call(
        content: current_content,
        operations: [{ "op" => "replace_exact", "old_text" => "Some content here.", "new_text" => "Updated content.", "count" => 1 }]
      )
      session.update!(
        operations_json: result[:applied],
        draft_content: result[:content]
      )

      expect {
        post commit_api_v1_plan_session_path(plan, session), headers: headers, as: :json
      }.to change(CoPlan::PlanVersion, :count).by(1)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("committed")
      expect(body["revision"]).to eq(plan.current_revision + 1)
      expect(body["version_id"]).to be_present
      expect(body["content_sha256"]).to be_present
    end

    it "commits with 0 operations — no version created" do
      session = create(:edit_session, plan: plan, actor_id: alice_token.id)

      expect {
        post commit_api_v1_plan_session_path(plan, session), headers: headers, as: :json
      }.not_to change(CoPlan::PlanVersion, :count)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("committed")
      expect(body["revision"]).to be_nil
    end

    it "commits with change_summary param" do
      session = create(:edit_session, plan: plan, actor_id: alice_token.id)
      current_content = plan.current_content
      result = CoPlan::Plans::ApplyOperations.call(
        content: current_content,
        operations: [{ "op" => "replace_exact", "old_text" => "Some content here.", "new_text" => "Changed.", "count" => 1 }]
      )
      session.update!(
        operations_json: result[:applied],
        draft_content: result[:content]
      )

      post commit_api_v1_plan_session_path(plan, session),
        params: { change_summary: "Fixed typos" },
        headers: headers,
        as: :json

      expect(response).to have_http_status(:ok)
      session.reload
      expect(session.change_summary).to eq("Fixed typos")
    end
  end

  describe "POST /api/v1/plans/:plan_id/operations with session_id" do
    it "accumulates operations in session" do
      session = create(:edit_session, plan: plan, actor_id: alice_token.id)

      post api_v1_plan_operations_path(plan),
        params: {
          session_id: session.id,
          base_revision: plan.current_revision,
          operations: [
            { op: "replace_exact", old_text: "Some content here.", new_text: "Updated content.", count: 1 }
          ]
        },
        headers: headers,
        as: :json

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["session_id"]).to eq(session.id)
      expect(body["applied"]).to eq(1)
      expect(body["operations_pending"]).to eq(1)

      session.reload
      expect(session.operations_json.length).to eq(1)
      expect(session.draft_content).to include("Updated content.")
    end

    it "second operation uses draft_content" do
      session = create(:edit_session, plan: plan, actor_id: alice_token.id)

      # First operation
      post api_v1_plan_operations_path(plan),
        params: {
          session_id: session.id,
          base_revision: plan.current_revision,
          operations: [
            { op: "replace_exact", old_text: "Some content here.", new_text: "First edit.", count: 1 }
          ]
        },
        headers: headers,
        as: :json
      expect(response).to have_http_status(:created)

      # Second operation uses the draft content from the first
      post api_v1_plan_operations_path(plan),
        params: {
          session_id: session.id,
          base_revision: plan.current_revision,
          operations: [
            { op: "replace_exact", old_text: "First edit.", new_text: "Second edit.", count: 1 }
          ]
        },
        headers: headers,
        as: :json
      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      expect(body["operations_pending"]).to eq(2)

      session.reload
      expect(session.draft_content).to include("Second edit.")
    end

    it "returns 404 when session not found" do
      post api_v1_plan_operations_path(plan),
        params: {
          session_id: "nonexistent-session",
          base_revision: plan.current_revision,
          operations: [
            { op: "replace_exact", old_text: "x", new_text: "y", count: 1 }
          ]
        },
        headers: headers,
        as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/plans/:plan_id/operations direct mode (no lease, no session)" do
    it "creates version directly" do
      plan # force creation before counting
      initial_revision = plan.current_revision

      expect {
        post api_v1_plan_operations_path(plan),
          params: {
            base_revision: initial_revision,
            operations: [
              { op: "replace_exact", old_text: "Some content here.", new_text: "Direct edit.", count: 1 }
            ]
          },
          headers: headers,
          as: :json
      }.to change(CoPlan::PlanVersion, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["revision"]).to eq(initial_revision + 1)
      expect(body["applied"]).to eq(1)
    end

    it "auto-rebases for non-conflicting edits with stale base_revision" do
      # Record current revision as our "base"
      stale_revision = plan.current_revision
      original_content = plan.current_content

      # Create an intervening version that edits a different part of the content
      # Original: "# Plan Content\n\nSome content here."
      # Intervening edit changes the heading
      intervening_content = original_content.sub("# Plan Content", "# Updated Plan Title")
      new_rev = plan.current_revision + 1
      intervening_version = CoPlan::PlanVersion.create!(
        plan: plan,
        revision: new_rev,
        content_markdown: intervening_content,
        actor_type: "human",
        actor_id: alice.id,
        operations_json: [{
          "op" => "replace_exact",
          "old_text" => "# Plan Content",
          "new_text" => "# Updated Plan Title",
          "resolved_range" => [0, 14],
          "new_range" => [0, 20],
          "delta" => 6
        }]
      )
      plan.update!(current_plan_version: intervening_version, current_revision: new_rev)

      # Now submit operation against the stale base_revision
      # "Some content here." exists in both old and new content (just shifted)
      expect {
        post api_v1_plan_operations_path(plan),
          params: {
            base_revision: stale_revision,
            operations: [
              { op: "replace_exact", old_text: "Some content here.", new_text: "Rebased edit.", count: 1 }
            ]
          },
          headers: headers,
          as: :json
      }.to change(CoPlan::PlanVersion, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["revision"]).to eq(new_rev + 1)
    end

    it "returns 409 for conflicting stale revision" do
      stale_revision = plan.current_revision
      original_content = plan.current_content

      # Create an intervening version that changes the same text
      intervening_content = original_content.sub("Some content here.", "Completely different text.")
      new_rev = plan.current_revision + 1
      intervening_version = CoPlan::PlanVersion.create!(
        plan: plan,
        revision: new_rev,
        content_markdown: intervening_content,
        actor_type: "human",
        actor_id: alice.id,
        operations_json: [{
          "op" => "replace_exact",
          "old_text" => "Some content here.",
          "new_text" => "Completely different text.",
          "resolved_range" => [16, 34],
          "new_range" => [16, 41],
          "delta" => 7,
          "count" => 1
        }]
      )
      plan.update!(current_plan_version: intervening_version, current_revision: new_rev)

      # Try to edit the same text that was already changed
      post api_v1_plan_operations_path(plan),
        params: {
          base_revision: stale_revision,
          operations: [
            { op: "replace_exact", old_text: "Some content here.", new_text: "My edit.", count: 1 }
          ]
        },
        headers: headers,
        as: :json

      expect(response).to have_http_status(:conflict)
    end
  end

  describe "stale rebase verification for non-replace ops" do
    let(:rich_content) { "# My Plan\n\n## Overview\n\nThis is the overview.\n\n## Goals\n\nWe want to achieve great things.\n\n## Timeline\n\nQ1 2026 launch." }
    let(:rich_plan) do
      p = CoPlan::Plan.create!(title: "Rich Plan", status: "considering", created_by_user: alice)
      v = CoPlan::PlanVersion.create!(plan: p, revision: 1, content_markdown: rich_content, actor_type: "human", actor_id: alice.id)
      p.update!(current_plan_version: v, current_revision: 1)
      p
    end

    def create_intervening_replace(plan, old_text, new_text)
      content = plan.current_content
      pos = content.index(old_text)
      new_content = content.sub(old_text, new_text)
      new_rev = plan.current_revision + 1
      v = CoPlan::PlanVersion.create!(
        plan: plan, revision: new_rev,
        content_markdown: new_content, actor_type: "human", actor_id: alice.id,
        operations_json: [{
          "op" => "replace_exact",
          "old_text" => old_text, "new_text" => new_text,
          "resolved_range" => [pos, pos + old_text.length],
          "new_range" => [pos, pos + new_text.length],
          "delta" => new_text.length - old_text.length
        }]
      )
      plan.update!(current_plan_version: v, current_revision: new_rev)
    end

    it "returns 409 when stale insert_under_heading targets a renamed heading" do
      stale_revision = rich_plan.current_revision

      # Intervening edit renames "## Goals" to "## Objectives" (same position, different text)
      create_intervening_replace(rich_plan, "## Goals", "## Objectives")

      post api_v1_plan_operations_path(rich_plan),
        params: {
          base_revision: stale_revision,
          operations: [{ op: "insert_under_heading", heading: "## Goals", content: "New goal item." }]
        },
        headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to include("heading")
    end

    it "succeeds when stale insert_under_heading heading is unchanged" do
      stale_revision = rich_plan.current_revision

      # Intervening edit changes unrelated content
      create_intervening_replace(rich_plan, "Q1 2026 launch.", "Q2 2026 launch.")

      post api_v1_plan_operations_path(rich_plan),
        params: {
          base_revision: stale_revision,
          operations: [{ op: "insert_under_heading", heading: "## Goals", content: "\nNew goal item." }]
        },
        headers: headers, as: :json

      expect(response).to have_http_status(:created)
    end

    it "returns 409 when stale delete_paragraph_containing target was modified" do
      stale_revision = rich_plan.current_revision

      # Intervening edit changes text inside the paragraph — TransformRange
      # catches the overlap since the edit range is inside the paragraph range
      create_intervening_replace(rich_plan, "great things", "small steps")

      post api_v1_plan_operations_path(rich_plan),
        params: {
          base_revision: stale_revision,
          operations: [{ op: "delete_paragraph_containing", needle: "great things" }]
        },
        headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
    end

    it "succeeds when stale delete_paragraph_containing needle still present" do
      stale_revision = rich_plan.current_revision

      # Intervening edit changes unrelated content
      create_intervening_replace(rich_plan, "Q1 2026 launch.", "Q2 2026 launch.")

      post api_v1_plan_operations_path(rich_plan),
        params: {
          base_revision: stale_revision,
          operations: [{ op: "delete_paragraph_containing", needle: "great things" }]
        },
        headers: headers, as: :json

      expect(response).to have_http_status(:created)
    end
  end

  describe "stale session commit verification for non-replace ops" do
    let(:rich_content) { "# My Plan\n\n## Overview\n\nThis is the overview.\n\n## Goals\n\nWe want to achieve great things.\n\n## Timeline\n\nQ1 2026 launch." }
    let(:rich_plan) do
      p = CoPlan::Plan.create!(title: "Rich Plan", status: "considering", created_by_user: alice)
      v = CoPlan::PlanVersion.create!(plan: p, revision: 1, content_markdown: rich_content, actor_type: "human", actor_id: alice.id)
      p.update!(current_plan_version: v, current_revision: 1)
      p
    end

    def create_intervening_replace(plan, old_text, new_text)
      content = plan.current_content
      pos = content.index(old_text)
      new_content = content.sub(old_text, new_text)
      new_rev = plan.current_revision + 1
      v = CoPlan::PlanVersion.create!(
        plan: plan, revision: new_rev,
        content_markdown: new_content, actor_type: "human", actor_id: alice.id,
        operations_json: [{
          "op" => "replace_exact",
          "old_text" => old_text, "new_text" => new_text,
          "resolved_range" => [pos, pos + old_text.length],
          "new_range" => [pos, pos + new_text.length],
          "delta" => new_text.length - old_text.length
        }]
      )
      plan.update!(current_plan_version: v, current_revision: new_rev)
    end

    it "raises conflict when stale session has insert_under_heading with renamed heading" do
      # Open session at rev 1
      post api_v1_plan_sessions_path(rich_plan), headers: headers, as: :json
      session_id = JSON.parse(response.body)["id"]

      # Apply insert_under_heading in the session
      post api_v1_plan_operations_path(rich_plan),
        params: {
          session_id: session_id,
          base_revision: rich_plan.current_revision,
          operations: [{ op: "insert_under_heading", heading: "## Goals", content: "\nNew goal." }]
        },
        headers: headers, as: :json
      expect(response).to have_http_status(:created)

      # Intervening edit renames the heading
      create_intervening_replace(rich_plan, "## Goals", "## Objectives")

      # Commit the stale session
      post commit_api_v1_plan_session_path(rich_plan, session_id), headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to include("Heading changed")
    end

    it "raises conflict when stale session has delete_paragraph_containing with modified target" do
      # Open session at rev 1
      post api_v1_plan_sessions_path(rich_plan), headers: headers, as: :json
      session_id = JSON.parse(response.body)["id"]

      # Apply delete_paragraph_containing in the session
      post api_v1_plan_operations_path(rich_plan),
        params: {
          session_id: session_id,
          base_revision: rich_plan.current_revision,
          operations: [{ op: "delete_paragraph_containing", needle: "great things" }]
        },
        headers: headers, as: :json
      expect(response).to have_http_status(:created)

      # Intervening edit changes text inside the paragraph — TransformRange
      # catches the overlap since the edit range is inside the paragraph range
      create_intervening_replace(rich_plan, "great things", "small steps")

      # Commit the stale session
      post commit_api_v1_plan_session_path(rich_plan, session_id), headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
    end
  end

  describe "POST /api/v1/plans/:plan_id/operations with lease_token (legacy mode)" do
    it "existing behavior unchanged" do
      lease_token = SecureRandom.hex(32)
      CoPlan::EditLease.acquire!(
        plan: plan,
        holder_type: "local_agent",
        holder_id: alice_token.id,
        lease_token: lease_token
      )

      expect {
        post api_v1_plan_operations_path(plan),
          params: {
            lease_token: lease_token,
            base_revision: plan.current_revision,
            operations: [
              { op: "replace_exact", old_text: "Some content here.", new_text: "Lease edit.", count: 1 }
            ]
          },
          headers: headers,
          as: :json
      }.to change(CoPlan::PlanVersion, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["revision"]).to eq(plan.current_revision + 1)
    end
  end
end
