require "rails_helper"

# A person editing a plan by hand is the highest-authority input the
# document gets. Everywhere else in the concurrency machinery a stale agent
# write gets transformed through intervening versions and applied anyway;
# here it doesn't. These specs pin the difference.
RSpec.describe "Human edit fence", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:initial_content) { "# Plan\n\nShip behind a flag in Q4.\n\nOwner: Sam.\n" }
  let!(:plan) do
    p = CoPlan::Plan.create!(title: "Rollout", created_by_user: alice)
    v = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: initial_content,
      actor_type: "local_agent", actor_id: alice.id,
      operations_json: []
    )
    p.update!(current_plan_version: v, current_revision: 1)
    p
  end

  before { alice_token }

  # The manual edit a person would make in the web editor.
  def hand_edit!(from: nil, to: nil, summary: "Edited in web UI", actor: alice)
    CoPlan::Plans::ReplaceContent.call(
      plan: plan.reload,
      new_content: plan.current_content.sub(from, to),
      base_revision: plan.current_revision,
      actor_type: "human",
      actor_id: actor.id,
      change_summary: summary
    )
  end

  def put_content(body, revision: nil)
    put api_v1_plan_content_path(plan),
      params: { base_revision: revision || plan.reload.current_revision, content: body },
      headers: headers, as: :json
  end

  describe "PUT /content" do
    it "lets an agent write when nobody has hand-edited the plan" do
      agent_has_read(plan, alice_token)

      put_content(initial_content + "\nAgent addendum.\n")

      expect(response).to have_http_status(:created)
    end

    it "refuses the write when a person edited after the agent last read" do
      agent_has_read(plan, alice_token)
      hand_edit!(from: "Q4", to: "Q3 — legal signed off on the earlier date")

      expect {
        put_content(initial_content + "\nAgent addendum.\n")
      }.not_to change(CoPlan::PlanVersion, :count)

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["code"]).to eq("human_edit_pending")
      expect(body["last_human_revision"]).to eq(2)
      expect(body["last_seen_revision"]).to eq(1)
      expect(plan.reload.current_content).to include("Q3 — legal signed off")
    end

    it "hands back the human's diff so the agent can keep their wording" do
      agent_has_read(plan, alice_token)
      hand_edit!(from: "Q4", to: "Q3", summary: "Legal cleared the earlier date")

      put_content(initial_content)

      body = JSON.parse(response.body)
      edit = body["human_edits"].sole
      expect(edit["revision"]).to eq(2)
      expect(edit["editor"]).to eq(alice.name)
      expect(edit["change_summary"]).to eq("Legal cleared the earlier date")
      expect(edit["diff"]).to include("Q3")
      expect(edit["diff"]).to include("Q4")
      expect(body["error"]).to include(alice.name)
      expect(body["resolve"]).to include("snapshot")
    end

    # The whole point of tracking reads rather than trusting base_revision:
    # the 409 tells the agent the current revision, and an agent that just
    # echoes it back would otherwise wipe out the edit it never saw.
    it "is not satisfied by bumping base_revision to the number in the error" do
      agent_has_read(plan, alice_token)
      hand_edit!(from: "Q4", to: "Q3")

      put_content(initial_content, revision: 2)

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["code"]).to eq("human_edit_pending")
      expect(plan.reload.current_content).to include("Q3")
    end

    it "lifts once the agent actually reads the plan" do
      agent_has_read(plan, alice_token)
      hand_edit!(from: "Q4", to: "Q3")
      put_content(initial_content)
      expect(response).to have_http_status(:conflict)

      get snapshot_api_v1_plan_path(plan), headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      current = JSON.parse(response.body)["current_content"]

      put_content(current + "\nAgent addendum.\n")

      expect(response).to have_http_status(:created)
      expect(plan.reload.current_content).to include("Q3")
      expect(plan.current_content).to include("Agent addendum.")
    end

    it "blocks a credential that has never read the plan at all" do
      hand_edit!(from: "Q4", to: "Q3")

      put_content(initial_content)

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["last_seen_revision"]).to eq(0)
      expect(body["error"]).to include("never read this plan")
    end

    # Receipts are per credential, not per person: a second agent running on
    # its own token hasn't seen anything just because the first one did.
    it "does not let one agent's read clear the fence for another" do
      other_token = create(:api_token, user: alice, raw_token: "test-token-other")
      agent_has_read(plan, alice_token)
      hand_edit!(from: "Q4", to: "Q3")
      get snapshot_api_v1_plan_path(plan), headers: headers, as: :json

      put api_v1_plan_content_path(plan),
        params: { base_revision: plan.reload.current_revision, content: initial_content },
        headers: { "Authorization" => "Bearer test-token-other" }, as: :json

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["code"]).to eq("human_edit_pending")
      expect(other_token.reload).to be_present
    end

    it "reports every unseen human edit, not just the last one" do
      agent_has_read(plan, alice_token)
      hand_edit!(from: "Q4", to: "Q3")
      hand_edit!(from: "Owner: Sam.", to: "Owner: Sam and Dana.")

      put_content(initial_content)

      body = JSON.parse(response.body)
      expect(body["human_edits"].map { |e| e["revision"] }).to eq([ 2, 3 ])
      expect(body["error"]).to include("2 edits")
    end

    it "ignores human edits the agent has already seen" do
      hand_edit!(from: "Q4", to: "Q3")
      agent_has_read(plan, alice_token)

      put_content(plan.reload.current_content + "\nAgent addendum.\n")

      expect(response).to have_http_status(:created)
    end

    # Agent-vs-agent staleness keeps its existing behavior: the operations
    # path rebases, the content path asks for a re-read. Neither is a fence.
    it "leaves another agent's edit to the ordinary stale-revision path" do
      agent_has_read(plan, alice_token)
      CoPlan::Plans::ReplaceContent.call(
        plan: plan, new_content: initial_content.sub("Q4", "Q2"),
        base_revision: 1, actor_type: "local_agent", actor_id: alice.id
      )

      put_content(initial_content, revision: 1)

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["code"]).to be_nil
      expect(body["error"]).to match(/Stale/)
    end
  end

  describe "POST /operations" do
    it "refuses to rebase over an unread human edit" do
      agent_has_read(plan, alice_token)
      hand_edit!(from: "Q4", to: "Q3")

      expect {
        post api_v1_plan_operations_path(plan),
          params: {
            base_revision: 1,
            operations: [ { op: "replace_exact", old_text: "Owner: Sam.", new_text: "Owner: Dana.", count: 1 } ]
          },
          headers: headers, as: :json
      }.not_to change(CoPlan::PlanVersion, :count)

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["code"]).to eq("human_edit_pending")
    end
  end

  describe "sessions" do
    it "refuses to open a session against content the agent has not read" do
      hand_edit!(from: "Q4", to: "Q3")

      expect {
        post api_v1_plan_sessions_path(plan), headers: headers, as: :json
      }.not_to change(CoPlan::EditSession, :count)

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["code"]).to eq("human_edit_pending")
    end

    it "refuses to commit a session a person edited underneath" do
      agent_has_read(plan, alice_token)
      post api_v1_plan_sessions_path(plan), headers: headers, as: :json
      session_id = JSON.parse(response.body)["id"]

      post api_v1_plan_operations_path(plan),
        params: {
          session_id: session_id, base_revision: 1,
          operations: [ { op: "replace_exact", old_text: "Owner: Sam.", new_text: "Owner: Dana.", count: 1 } ]
        }, headers: headers, as: :json
      expect(response).to have_http_status(:created)

      hand_edit!(from: "Q4", to: "Q3")

      expect {
        post commit_api_v1_plan_session_path(plan, session_id), headers: headers, as: :json
      }.not_to change(CoPlan::PlanVersion, :count)

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["code"]).to eq("human_edit_pending")
      expect(plan.reload.current_content).to include("Owner: Sam.")
    end
  end

  describe "read receipts" do
    it "records the revision handed over by GET /plans/:id" do
      get api_v1_plan_path(plan), headers: headers, as: :json

      expect(receipt_revision).to eq(1)
    end

    it "records the revision an agent writes, since it has seen that content" do
      agent_has_read(plan, alice_token)
      put_content(initial_content + "\nAgent addendum.\n")

      expect(receipt_revision).to eq(2)
    end

    it "never walks backwards" do
      agent_has_read(plan, alice_token, revision: 5)
      get api_v1_plan_path(plan), headers: headers, as: :json

      expect(receipt_revision).to eq(5)
    end

    def receipt_revision
      CoPlan::PlanRead.revision_for(plan: plan, reader_type: "api_token", reader_id: alice_token.id)
    end
  end

  describe "checkbox ticks" do
    # Ticking a box in the UI is a person saying something about the plan's
    # state, and it goes through the same human-version path as any other
    # manual edit. It raises the fence like anything else would.
    it "counts as a human edit" do
      agent_has_read(plan, alice_token)
      CoPlan::Plans::ReplaceContent.call(
        plan: plan, new_content: initial_content + "\n- [x] Flag wired up\n",
        base_revision: 1, actor_type: "human", actor_id: alice.id,
        change_summary: "Checked an item"
      )

      put_content(initial_content)

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["code"]).to eq("human_edit_pending")
    end
  end
end
