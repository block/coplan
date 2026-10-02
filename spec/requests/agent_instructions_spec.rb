require "rails_helper"

RSpec.describe "Agent Instructions", type: :request do
  it "advertises the five-level cap in the organizing guide" do
    get agent_instructions_organizing_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include("at most 5 levels deep", "The depth cap is 5")
  end

  describe "GET /agent-instructions" do
    it "returns markdown content" do
      get agent_instructions_path
      expect(response).to have_http_status(:success)
      expect(response.content_type).to include("text/markdown")
      expect(response.body).to include("# CoPlan API")
      expect(response.body).to include("max 5 levels deep")
      expect(response.body).to include("```mermaid")
    end

    it "includes plan types when they exist" do
      create(:plan_type, name: "Design Doc", description: "For design documents")

      get agent_instructions_path

      expect(response.body).to include("### Plan Types")
      expect(response.body).to include("Design Doc")
      expect(response.body).to include("For design documents")
    end

    it "shows message when no plan types are configured" do
      get agent_instructions_path

      expect(response.body).to include("### Plan Types")
      expect(response.body).to include("No plan types are currently configured")
    end

    it "lists multiple plan types sorted by name" do
      create(:plan_type, name: "RFC")
      create(:plan_type, name: "Design Doc")

      get agent_instructions_path

      body = response.body
      expect(body.index("Design Doc")).to be < body.index("RFC")
    end

    it "documents plan_type in create plan section" do
      get agent_instructions_path
      expect(response.body).to include('"plan_type"')
    end

    it "sets writing-style ground rules with a type-level override" do
      get agent_instructions_path

      expect(response.body).to include("## Writing Style")
      # Anti-metadata rules: the platform records dates/authors/status/versions.
      expect(response.body).to include("The platform already records it.")
      expect(response.body).to include("do not invent one")
      # Plain-language rules with the override escape hatch.
      expect(response.body).to include("the type wins")
      expect(response.body).to include("Write like a runbook, not a keynote.")
    end

    it "declares identity once through the session token" do
      get agent_instructions_path

      expect(response.body).to include("Declare it here once; the token supplies it on every later call.")
      expect(response.body).to include("Do not send attribution fields.")
      expect(response.body).not_to include("per-request override of who is writing")
      expect(response.body).not_to include('"body_markdown": "Good point, I will address this.", "agent_name"')
    end

    it "uses request authentication for the first token mint when the host provides it" do
      allow(CoPlan.configuration).to receive(:api_authenticate).and_return(->(_request) { nil })

      get agent_instructions_path

      mint_example = response.body.split("```bash", 2).last.split("```", 2).first
      expect(response.body).to include("you do not need a token from Settings")
      expect(mint_example).to include("curl -s -X POST")
      expect(mint_example).not_to include("Authorization: Bearer")
      expect(response.body).to include('Authorization: Bearer $TOKEN')
      expect(response.body).not_to include("minted from your long-lived one")
      expect(response.body).to include("Do not use a session token to mint another token")
    end

    it "uses the host's authenticated mint command when configured" do
      allow(CoPlan.configuration).to receive(:api_authenticate).and_return(->(_request) { nil })
      allow(CoPlan.configuration).to receive(:agent_mint_curl_prefix).and_return("sq curl -s")

      get agent_instructions_path

      expect(response.body.scan("sq curl -s -X POST").length).to eq(2)
    end

    it "documents safe harness-specific live setup for plan-scoped work" do
      get agent_instructions_path

      expect(response.body).to include("## Live Setup: Choose a Wake Path Safely")
      expect(response.body).to include("check whether your harness has a way to start another model turn")
      expect(response.body).to include("Claiming a presence pill without running a wait, bridge, or webhook is not attachment")
      expect(response.body).to include("Never run an unbounded wait in the foreground")
      expect(response.body).to include("| Codex desktop |")
      expect(response.body).to include("| Codex CLI / IDE |")
      expect(response.body).to include("in-chat scheduled follow-up that drains `wait=0`")
      expect(response.body).to include("`claude --resume <session-id> -p <event>`")
      expect(response.body).to include("Starting an ACP server creates a different agent")
      expect(response.body).to include("ACP is intentionally not an attachment path here")
      expect(response.body).to include("ACP-created agents are a separate deployment mode")
      expect(response.body).not_to include("coplan-bridge --acp")
      expect(response.body).to include("Harness names are hints, not proof")
      expect(response.body).to include("degraded fallback, not successful live setup")
      expect(response.body).not_to include("optional-but-recommended upgrade")
      expect(response.body).not_to include("Correct, just not live")
    end

    it "walks agents through folder, type, and template before creating" do
      get agent_instructions_path

      expect(response.body).to include("**Pick the folder.**")
      expect(response.body).to include("**Pick the type.**")
      expect(response.body).to include("template_content")
      expect(response.body).to include("/api/v1/plan_types")
      expect(response.body).to include('"folder_path"')
      expect(response.body).to include("fallback of last resort")
    end

    it "uses a real configured type (not General) in the create example" do
      create(:plan_type, name: "General", description: "Catch-all")
      create(:plan_type, name: "Design Doc", description: "For design documents")

      get agent_instructions_path

      expect(response.body).to include('"plan_type": "Design Doc"')
    end

    # Type names are admin-controlled free text; the example must survive a
    # name that would break JSON quoting or the surrounding shell quoting.
    it "keeps the create example valid for hostile plan type names" do
      create(:plan_type, name: %q(Bob's "Special" Doc))

      get agent_instructions_path

      # JSON-escaped double quotes, shell-escaped single quote.
      expect(response.body).to include('\"Special\"')
      expect(response.body).to include(%q(Bob'\''s))
    end

    it "marks which plan types carry a template" do
      create(:plan_type, name: "RFC", template_content: "# RFC")
      create(:plan_type, name: "Bare", template_content: nil)

      get agent_instructions_path

      expect(response.body).to match(/`RFC`.*yes — fetch and follow it/)
      expect(response.body).to match(/`Bare`.*\| —/)
    end

    it "distinguishes citations, internal section links, and structured references" do
      get agent_instructions_path

      expect(response.body).to include("Citations and internal cross-references")
      expect(response.body).to include("[§3.1](#section-3-1)")
      expect(response.body).to include("structured, document-level inventory")
      expect(response.body).to include("one **References** section")
      expect(response.body).to include("source title, type, and domain")
      expect(response.body).to include("click jumps to it")
    end

    it "builds example URLs from the request base (root mount)" do
      get agent_instructions_path
      expect(response.body).to include("http://www.example.com/api/v1/plans")
      expect(response.body).not_to include("example.com//api")
    end

    it "includes the engine mount prefix in example URLs" do
      # Host apps may mount the engine under a prefix (HOST_APP_GUIDE
      # documents mount at "/coplan"); examples must include it or agents
      # 404 on their first read.
      get agent_instructions_path, env: { "SCRIPT_NAME" => "/coplan" }
      expect(response.body).to include("http://www.example.com/coplan/api/v1/plans")
    end
  end

  describe "content negotiation" do
    # What Chrome/Firefox/Safari actually send.
    let(:browser_accept) { "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" }

    context "non-browser clients (agents, curl)" do
      it "serves raw markdown for curl's default Accept: */*" do
        get agent_instructions_path, headers: { "Accept" => "*/*" }

        expect(response).to have_http_status(:success)
        expect(response.content_type).to include("text/markdown")
        expect(response.body).to include("# CoPlan API")
        expect(response.body).not_to include("<html")
      end

      it "serves raw markdown for Accept: text/markdown" do
        get agent_instructions_path, headers: { "Accept" => "text/markdown" }

        expect(response.content_type).to include("text/markdown")
        expect(response.body).to include("# CoPlan API")
      end

      it "serves byte-identical markdown regardless of non-HTML Accept header" do
        get agent_instructions_path
        baseline = response.body

        get agent_instructions_path, headers: { "Accept" => "*/*" }
        expect(response.body).to eq(baseline)

        get agent_instructions_path, headers: { "Accept" => "text/markdown" }
        expect(response.body).to eq(baseline)
      end
    end

    context "browsers (Accept header includes text/html)" do
      it "redirects to the human setup page" do
        get agent_instructions_path, headers: { "Accept" => browser_accept }

        expect(response).to redirect_to(agent_setup_path)
      end

      it "keeps the engine mount point in the redirect" do
        get agent_instructions_path, headers: { "Accept" => browser_accept }, env: { "SCRIPT_NAME" => "/coplan" }

        expect(response).to redirect_to("/coplan/_/agent/setup")
      end

      it "still serves raw markdown at .md even when the client accepts HTML" do
        get agent_instructions_path(format: :md), headers: { "Accept" => browser_accept }

        expect(response.content_type).to include("text/markdown")
        expect(response.body).to include("# CoPlan API")
        expect(response.body).not_to include("<html")
      end

      it "redirects .html to setup regardless of the Accept header" do
        get agent_instructions_path(format: :html), headers: { "Accept" => "*/*" }

        expect(response).to redirect_to(agent_setup_path)
      end
    end
  end

  describe "GET /_/agent/instructions" do
    it "shows the current instructions as a separate human-readable page" do
      get agent_instructions_reference_path

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/html")
      expect(response.body).to include("Agent instructions")
      expect(response.body).to include("CoPlan API")
      expect(response.body).to include(%(href="#{agent_setup_path}"))
    end

    it "renders with host request authentication and configured plan types" do
      allow(CoPlan.configuration).to receive(:api_authenticate).and_return(->(_request) { nil })
      create(:plan_type, name: "Design Doc", description: "For design documents")

      get agent_instructions_reference_path, headers: { "Accept" => "text/html" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("you do not need a token from Settings")
      expect(response.body).to include("Design Doc")
    end

    it "renders when the engine is mounted under a prefix" do
      get agent_instructions_reference_path, env: { "SCRIPT_NAME" => "/coplan" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("http://www.example.com/coplan/api/v1/plans")
    end
  end
end
