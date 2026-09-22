require "rails_helper"

RSpec.describe "Human document editor", type: :request do
  let(:author) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:token) { SecureRandom.hex(32) }
  before { sign_in_as(author) }

  def acquire
    post editor_lease_plan_path(plan), params: { lease_token: token }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "provides a human-first rich editor and creates a private human version" do
    get new_plan_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('aria-label="Text formatting"', 'data-command="bold"')
    post plans_path, params: { plan: { title: "Human document" }, content: "My **draft**" }, as: :json
    expect(response).to have_http_status(:ok)
    created = CoPlan::Plan.find(response.parsed_body["id"])
    expect(created).to be_draft
    expect(created.current_plan_version.actor_type).to eq("human")
    expect(response.parsed_body["edit_url"]).to end_with("/edit")
    subscription = Nokogiri::HTML.fragment(response.parsed_body["subscription_html"]).at_css("turbo-cable-stream-source")
    expect(subscription["channel"]).to eq("Turbo::StreamsChannel")
    expect(Turbo::StreamsChannel.verified_stream_name(subscription["signed-stream-name"])).to eq(created.to_gid_param)
  end

  it "renders the host language suggestions while accepting arbitrary fence info" do
    expect(CoPlan::Configuration.new.editor_code_languages).to include("javascript", "ruby", "mermaid")
    allow(CoPlan.configuration).to receive(:editor_code_languages).and_return([ "elixir", "custom-build" ])
    get new_plan_path
    options = Nokogiri::HTML(response.body).css("#coplan-code-languages option").map { |option| option["value"] }
    expect(options).to eq([ "elixir", "custom-build" ])
    expect(response.body).to include('aria-label="Insert code block"', 'data-mode="dual"')
    patch update_content_plan_path(plan), params: { content: "```unknown extra=1\nbody\n```", base_revision: 1 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(plan.reload.current_content).to eq("```unknown extra=1\nbody\n```")
  end

  it "deduplicates creation retries with a browser key" do
    key = SecureRandom.uuid
    post plans_path, params: { creation_key: key, plan: { title: "Retry document" }, content: "First draft" }, as: :json
    expect(response).to have_http_status(:ok)
    id = response.parsed_body["id"]
    expect {
      post plans_path, params: { creation_key: key, plan: { title: "Retry document" }, content: "Changed retry" }, as: :json
    }.not_to change(CoPlan::Plan, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => id, "content" => "First draft")
  end

  it "renders an HTML lease conflict with the submitted draft intact" do
    CoPlan::EditLease.acquire!(plan: plan, holder_type: "local_agent", holder_id: author.id, lease_token: "agent-token")
    patch plan_path(plan), params: { plan: { title: "Uncommitted title" } }
    expect(response).to have_http_status(:conflict)
    expect(response.media_type).to eq("text/html")
    expect(response.body).to include("Uncommitted title", "Changes weren’t saved")
    expect(plan.reload.title).not_to eq("Uncommitted title")
    patch update_content_plan_path(plan), params: { content: "Retained content", base_revision: 1 }
    expect(response).to have_http_status(:conflict)
    expect(response.media_type).to eq("text/html")
    expect(response.body).to include("Retained content")
  end

  it "keeps in-page lease conflicts in place with a toast" do
    CoPlan::EditLease.acquire!(plan: plan, holder_type: "local_agent", holder_id: author.id, lease_token: "agent-token")
    patch plan_path(plan), params: { plan: { title: "Uncommitted title" } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    expect(response).to have_http_status(:conflict)
    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.body).to include('action="append" target="coplan-toasts"', "Plan is currently being edited in another session")
    expect(plan.reload.title).not_to eq("Uncommitted title")
  end

  it "validates blank creation without persisting a plan" do
    expect { post plans_path, params: { plan: { title: "" }, content: "" }, as: :json }.not_to change(CoPlan::Plan, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "saves in place without a session lease and publishes an authoritative snapshot" do
    patch update_content_plan_path(plan), params: { content: "New", base_revision: 1 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("revision" => 2, "content" => "New", "title" => plan.title)
    expect(plan.reload.current_content).to eq("New")
    expect(plan.edit_lease).to be_nil
    get editor_state_plan_path(plan), as: :json
    expect(response.parsed_body["content"]).to eq("New")
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "allows multiple open browsers without acquiring a lock" do
    acquire
    post editor_lease_plan_path(plan), params: { lease_token: SecureRandom.hex(32) }, as: :json
    expect(response).to have_http_status(:ok)
    expect(plan.reload.edit_lease).to be_nil
  end

  it "merges stale disjoint edits and rejects overlapping edits atomically" do
    plan.current_plan_version.update!(content_markdown: "Alpha. Beta.")
    patch update_content_plan_path(plan), params: { content: "Alpha! Beta.", base_revision: 1 }, as: :json
    expect(response).to have_http_status(:ok)
    patch update_content_plan_path(plan), params: { content: "Alpha. Beta!", base_revision: 1 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(plan.reload.current_content).to eq("Alpha! Beta!")
    original_title = plan.title
    patch update_content_plan_path(plan), params: { content: "Alpha? Beta.", base_revision: 1, plan: { title: "Bad" } }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("code" => "overlapping_edits", "content" => "Alpha! Beta!", "revision" => 3)
    expect(plan.reload.title).to eq(original_title)
  end

  it "rejects an unavailable base and includes the current snapshot" do
    patch update_content_plan_path(plan), params: { content: "Stale", base_revision: 0 }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["revision"]).to eq(1)
  end

  it "retires a legacy human lease without acquiring a replacement" do
    CoPlan::EditLease.acquire!(plan: plan, holder_type: "human", holder_id: author.id, lease_token: token)
    delete editor_lease_plan_path(plan), as: :json
    expect(response).to have_http_status(:ok)
    expect(plan.reload.edit_lease).to be_nil
  end

  it "rolls content back when metadata is invalid" do
    original = plan.current_content
    expect(CoPlan::Broadcaster).not_to receive(:replace_plan_content)
    expect {
      patch update_content_plan_path(plan), params: { content: "New text", base_revision: 1, plan: { title: "" } }, as: :json
    }.not_to change(CoPlan::PlanVersion, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(plan.reload.current_content).to eq(original)
  end

  it "detects conflicting metadata even when the body revision has not changed" do
    baseline = plan.title
    plan.update!(title: "Remote title")
    patch update_content_plan_path(plan), params: { content: plan.current_content, base_revision: 1,
      plan: { title: "Local title" }, base_metadata: { title: baseline } }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(plan.reload.title).to eq("Remote title")
  end

  it "respects a live agent lease and saves after its release" do
    lease = CoPlan::EditLease.acquire!(plan: plan, holder_type: "local_agent", holder_id: author.id, lease_token: token)
    patch update_content_plan_path(plan), params: { content: "New text", base_revision: 1 }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["code"]).to eq("edit_locked")
    lease.release!(lease_token: token)
    patch update_content_plan_path(plan), params: { content: "New text", base_revision: 1 }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "authorizes editor state and lease compatibility" do
    sign_in_as(create(:coplan_user))
    post editor_lease_plan_path(plan), params: { lease_token: token }, as: :json
    expect(response).to have_http_status(:not_found)
    get editor_state_plan_path(plan), as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "previews tables and Mermaid without saving or executing raw HTML" do
    expect {
      post preview_draft_plans_path, params: { content: "| A | B |\n|---|---|\n| 1 | 2 |\n\n```mermaid\ngraph TD; A-->B\n```\n<script>alert(1)</script>" }
    }.not_to change(CoPlan::PlanVersion, :count)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("<table>", 'lang="mermaid"', 'coplan--mermaid')
    expect(response.body).not_to include("<script>")
  end
end
