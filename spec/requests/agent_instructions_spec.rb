require "rails_helper"

RSpec.describe "Agent Instructions", type: :request do
  describe "GET /agent-instructions" do
    it "returns markdown content" do
      get agent_instructions_path
      expect(response).to have_http_status(:success)
      expect(response.content_type).to include("text/markdown")
      expect(response.body).to include("# CoPlan API")
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
end
