require "rails_helper"

RSpec.describe "Agent Instructions", type: :request do
  describe "GET /agent-instructions" do
    it "returns markdown content" do
      get agent_instructions_path
      expect(response).to have_http_status(:success)
      expect(response.content_type).to include("text/markdown")
      expect(response.body).to include("# CoPlan API")
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
      it "serves a rendered HTML page with the instructions content" do
        get agent_instructions_path, headers: { "Accept" => browser_accept }

        expect(response).to have_http_status(:success)
        expect(response.content_type).to include("text/html")
        expect(response.body).to include("Connect your AI agent")
        # The same markdown document, rendered — not served raw.
        expect(response.body).to include("CoPlan API")
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
        expect(response.body).to include("# CoPlan API")
        expect(response.body).not_to include("<html")
      end

      it "forces the HTML page at .html regardless of the Accept header" do
        get agent_instructions_path(format: :html), headers: { "Accept" => "*/*" }

        expect(response.content_type).to include("text/html")
        expect(response.body).to include("Connect your AI agent")
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
