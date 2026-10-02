require "rails_helper"

RSpec.describe "Agent Instructions", type: :request do
  describe "GET /agent-instructions" do
    it "returns markdown content" do
      get agent_instructions_path
      expect(response).to have_http_status(:success)
      expect(response.content_type).to include("text/markdown")
      expect(response.body).to include("# CoPlan for Agents")
    end

    it "covers the basics every agent needs, in order" do
      get agent_instructions_path
      body = response.body

      steps = [ "## 1. Mint a session token", "## 2. Read a plan", "## 3. Edit a plan",
                "## 4. Answer comments", "## 5. Create a plan" ]
      positions = steps.map { |step| body.index(step) }
      expect(positions).to all(be_present)
      expect(positions).to eq(positions.sort)
      expect(body).to include("/api/v1/tokens")
      expect(body).to include("human_edit_pending")
    end

    it "links every topic guide, and nothing it doesn't serve" do
      get agent_instructions_path

      linked = response.body.scan(%r{http://www\.example\.com/agent-instructions/([a-z/-]+)}).flatten.uniq
      expect(linked).to match_array(CoPlan::AgentInstructionsController::GUIDES.keys)
    end

    it "declares identity once through the session token" do
      get agent_instructions_path

      expect(response.body).to include("You declare who you are once, here.")
      expect(response.body).to include("Do not send `agent_name` or other attribution fields on later calls")
      expect(response.body).to include(%("harness": "claude-code"))
    end

    it "only sets up live sessions where something can wake the agent" do
      get agent_instructions_path
      body = response.body

      expect(body).to include("## 6. Stay for feedback")
      expect(body).to include("Show yourself as present only if something can wake you.")
      expect(body).to include("Do not run a wait in the foreground unless your principal asked you to watch the plan.")
      expect(body).to include("An environment name is a hint, not proof.")
      expect(body).not_to include("coplan-bridge --acp")
    end

    it "sets writing-style ground rules with a type-level override" do
      get agent_instructions_path

      expect(response.body).to include("## Writing rules")
      expect(response.body).to include("Do not write metadata in the body.")
      expect(response.body).to include("the type wins")
      expect(response.body).to include("Write like a runbook, not a keynote.")
    end

    it "walks agents through folder, type, and template before creating" do
      get agent_instructions_path

      expect(response.body).to include("/api/v1/library")
      expect(response.body).to include("/api/v1/plan_types")
      expect(response.body).to include("template_content")
      expect(response.body).to include('"folder_path"')
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

    it "includes the host's auth instructions" do
      get agent_instructions_path
      expect(response.body).to include(CoPlan.configuration.agent_auth_instructions.lines.first.strip)
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
      expect(response.body).to include("http://www.example.com/coplan/agent-instructions/editing")
    end
  end

  describe "GET /agent-instructions/:guide" do
    CoPlan::AgentInstructionsController::GUIDES.each_key do |guide|
      it "serves the #{guide} guide as markdown" do
        get agent_instructions_guide_path(guide: guide)

        expect(response).to have_http_status(:success)
        expect(response.content_type).to include("text/markdown")
        expect(response.body).to start_with("# ")
        expect(response.body).not_to include("http://www.example.com//")
      end
    end

    it "404s an unknown guide with a pointer back to the primer" do
      get agent_instructions_guide_path(guide: "nope")

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("http://www.example.com/agent-instructions")
    end

    it "keeps the organizing guide at its published path" do
      get agent_instructions_organizing_path

      expect(response).to have_http_status(:success)
      expect(response.body).to include("# Organizing a Library")
      expect(response.body).to include("up to #{CoPlan::Folder::MAX_DEPTH} levels deep")
    end

    describe "comments" do
      it "uses the open/resolved lifecycle" do
        get agent_instructions_guide_path(guide: "comments")
        body = response.body

        expect(body).to include("A thread is `open` until someone resolves it.")
        expect(body).not_to match(/pending|todo|discard|dismiss/)
      end
    end

    describe "editing" do
      it "explains the edit lock that blocks every write" do
        get agent_instructions_guide_path(guide: "editing")
        expect(response.body).to include(%("code": "edit_locked"))
        expect(response.body).to include("including content replacement and operations")
      end
    end

    describe "creating" do
      it "lists plan types with template markers" do
        create(:plan_type, name: "RFC", description: "For proposals", template_content: "# RFC")
        create(:plan_type, name: "Bare", template_content: nil)

        get agent_instructions_guide_path(guide: "creating")
        body = response.body

        expect(body).to include("## Plan types")
        expect(body).to match(/`RFC` \| For proposals \| yes — fetch and follow it/)
        expect(body).to match(/`Bare` .*\| — \|/)
        expect(body.index("`Bare`")).to be < body.index("`RFC`")
      end

      it "advertises the configured folder depth" do
        get agent_instructions_guide_path(guide: "creating")
        expect(response.body).to include("up to #{CoPlan::Folder::MAX_DEPTH} levels deep")
      end

      it "says so when no plan types are configured" do
        get agent_instructions_guide_path(guide: "creating")
        expect(response.body).to include("No plan types are currently configured")
      end
    end

    describe "markdown" do
      it "covers diagrams, tables, and the three kinds of links" do
        get agent_instructions_guide_path(guide: "markdown")
        body = response.body

        expect(body).to include("```mermaid")
        expect(body).to include("## Tables")
        expect(body).to include("[§3.1](#section-3-1)")
        expect(body).to include("[^queue-depth]")
        expect(body).to include("Each selection is a hand edit.")
      end
    end

    describe "presentations" do
      it "documents inline deck regions, not a deck plan type" do
        get agent_instructions_guide_path(guide: "presentations")
        body = response.body

        expect(body).to include("::: {.presentation #q3-review theme=\"coplan\"}")
        expect(body).to include("Outside a region, `---` is a horizontal rule.")
        expect(body).not_to include("behavior")
      end
    end

    describe "live" do
      it "gives Amp a wake that works between turns" do
        get agent_instructions_guide_path(guide: "live/amp")
        expect(response.body).to include("coplan-bridge --adapter amp --session")
        expect(response.body).to include("events?wait=0")
      end

      it "gives Codex desktop a scheduled follow-up instead of a held connection" do
        get agent_instructions_guide_path(guide: "live/codex")
        expect(response.body).to include("scheduled follow-up")
        expect(response.body).to include("Do not hold a request open between runs.")
      end

      it "keeps ACP agents out of attachment" do
        get agent_instructions_guide_path(guide: "live/bridge")
        expect(response.body).to include("It is not the conversation that wrote the plan")
        expect(response.body.index("--adapter claude")).to be < response.body.index("--acp")
      end

      it "never sends per-request agent names" do
        %w[live live/claude-code live/amp live/codex live/hosted].each do |guide|
          get agent_instructions_guide_path(guide: guide)
          expect(response.body).not_to include(%("agent_name":)), guide
        end
      end

      it "documents the authority contract" do
        get agent_instructions_guide_path(guide: "live")
        expect(response.body).to include(%(authority: "principal"))
        expect(response.body).to include(%(authority: "collaborator"))
      end
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
        expect(response.body).to include("# CoPlan for Agents")
        expect(response.body).not_to include("<html")
      end

      it "serves raw markdown for Accept: text/markdown" do
        get agent_instructions_path, headers: { "Accept" => "text/markdown" }

        expect(response.content_type).to include("text/markdown")
        expect(response.body).to include("# CoPlan for Agents")
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
      it "serves a rendered HTML page with the instructions content" do
        get agent_instructions_path, headers: { "Accept" => browser_accept }

        expect(response).to have_http_status(:success)
        expect(response.content_type).to include("text/html")
        expect(response.body).to include("Connect your AI agent")
        # The same markdown document, rendered — not served raw.
        expect(response.body).to include("CoPlan for Agents")
        expect(response.body).to include("markdown-rendered")
      end

      it "includes a copy-to-clipboard element carrying the raw instructions URL" do
        get agent_instructions_path, headers: { "Accept" => browser_accept }

        expect(response.body).to include('data-controller="coplan--clipboard"')
        expect(response.body).to include(%(data-coplan--clipboard-text-value="http://www.example.com/agent-instructions"))
      end

      it "shows a curl example and links to the raw markdown" do
        get agent_instructions_path, headers: { "Accept" => browser_accept }

        expect(response.body).to include("curl -s http://www.example.com/agent-instructions")
        expect(response.body).to include("/agent-instructions.md")
      end

      it "still serves raw markdown at .md even when the client accepts HTML" do
        get agent_instructions_path(format: :md), headers: { "Accept" => browser_accept }

        expect(response.content_type).to include("text/markdown")
        expect(response.body).to include("# CoPlan for Agents")
        expect(response.body).not_to include("<html")
      end

      it "forces the HTML page at .html regardless of the Accept header" do
        get agent_instructions_path(format: :html), headers: { "Accept" => "*/*" }

        expect(response.content_type).to include("text/html")
        expect(response.body).to include("Connect your AI agent")
      end

      it "renders guides as HTML too, so links from the primer page stay browsable" do
        get agent_instructions_guide_path(guide: "live/claude-code"), headers: { "Accept" => browser_accept }

        expect(response.content_type).to include("text/html")
        expect(response.body).to include("<title>Live Sessions in Claude Code — CoPlan</title>")
        expect(response.body).to include("markdown-rendered")
        expect(response.body).to include("/agent-instructions/live/claude-code.md")
        expect(response.body).to include(%(data-coplan--clipboard-text-value="http://www.example.com/agent-instructions/live/claude-code"))
      end

      it "renders the signed-in nav chrome for signed-in users" do
        user = create(:coplan_user, name: "Naveen Chrome")
        sign_in_as(user)

        get agent_instructions_path, headers: { "Accept" => browser_accept }

        expect(response.body).to include("Naveen Chrome")
      end
    end
  end
end
