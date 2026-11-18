require "rails_helper"

RSpec.describe "Document components", type: :request do
  let(:user) { create(:coplan_user) }
  let(:catalog) { CoPlan::ComponentCatalog.new }
  let(:content) do
    <<~'MD'
      # Demo

      ::: {.component #retry type="diagram" uses="maths@1" title="Retry flow"}

      const { delay } = await import("maths");
      diagram.node("retry", "Retry " + delay(2));

      :::
    MD
  end

  before do
    allow(CoPlan.configuration).to receive(:component_catalog).and_return(catalog)
    catalog.library("maths@1", source: "export const delay = n => n * 10", example: "delay(2)")
  end

  it "serves a fixed sandbox even on a direct visit" do
    get component_frame_path, params: { source: "ignored-component-input" }
    expect(response).to have_http_status(:ok)
    nonce = Nokogiri::HTML.fragment(response.body).at_css("script")["nonce"]
    expect(response.headers["Content-Security-Policy"]).to include("sandbox allow-scripts;", "frame-ancestors 'self'", "connect-src 'none'", "'nonce-#{nonce}'")
    expect(response.headers["Content-Security-Policy"]).not_to include("allow-same-origin", "'unsafe-eval'")
    expect(response.headers["Connection-Allowlist"]).to eq("()")
    expect(response.body).not_to include("ignored-component-input")
    allow(CoPlan.configuration).to receive(:components_enabled).and_return(false)
    get component_frame_path
    expect(response).to have_http_status(:not_found)
  end

  it "retains modules for each version and signs whole-component comments" do
    sign_in_as(user)
    plan = CoPlan::Plans::Create.call(title: "Demo", content:, user:, actor_type: "human")
    first = plan.current_plan_version
    catalog.library("maths@1", source: "export const delay = n => n * 20", example: "delay(2)")
    get plan_page_path(plan)
    block = Nokogiri::HTML.fragment(response.body).at_css("figure#retry")
    payload = JSON.parse(block["data-coplan--component-program-value"])
    expect(payload.fetch("libraries").keys).to contain_exactly("diagram", "maths")
    expect(payload.dig("libraries", "maths")).to include("* 10")
    expect(first.component_catalog.dig("libraries", "maths@1", "sha256")).to eq(Digest::SHA256.hexdigest(payload.dig("libraries", "maths")))
    expect(block.at_css("iframe")["sandbox"]).to eq("allow-scripts")
    target = JSON.parse(block.at_css("button")["data-source-target"])
    resolved = CoPlan::Plans::SourceTargets.resolve(target["token"], first.content_markdown)
    expect(resolved).to include("kind" => "component", "label" => "Retry flow")
    expect(first.content_markdown[resolved["start"]...resolved["end"]]).to eq(content.split("\n\n", 2).last.chomp)
    expect(CoPlan::Plans::SourceTargets.new(first.content_markdown).ranges).to include([ "component", resolved["start"], resolved["end"] ])

    CoPlan::Plans::ReplaceContent.call(plan:, new_content: content + "\nReview note.\n", base_revision: plan.current_revision,
      actor_type: "human", actor_id: user.id)
    expect(plan.reload.current_plan_version.component_catalog.dig("libraries", "maths@1", "source")).to include("* 20")
    get plan_version_page_path(plan, first)
    historical = Nokogiri::HTML.fragment(response.body).at_css("figure#retry")
    expect(JSON.parse(historical["data-coplan--component-program-value"]).dig("libraries", "maths")).to include("* 10")
    expect(first.reload.component_catalog.dig("libraries", "maths@1", "source")).to include("* 10")
  end

  it "keeps source visible for an unknown library, conflicts, and disabled execution" do
    sign_in_as(user)
    catalog.library("diagram@2", source: "export const version = 2", example: "version")
    post preview_draft_plans_path, params: { content: content.sub("maths@1", "missing@1") }
    expect(response.body).to include("Unknown component library: missing@1", "diagram.node")
    expect(response.body).not_to include("<iframe")
    post preview_draft_plans_path, params: { content: content.sub("maths@1", "diagram@2") }
    expect(response.body).to include("Conflicting versions of diagram")
    allow(CoPlan.configuration).to receive(:components_enabled).and_return(false)
    post preview_draft_plans_path, params: { content: }
    expect(response.body).to include("diagram.node")
    expect(response.body).not_to include("<iframe")
  end
end
