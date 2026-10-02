require "rails_helper"

RSpec.describe "Agent setup", type: :request do
  let(:browser_accept) { "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }

  it "serves a short Markdown setup guide at the reserved path" do
    expect(agent_setup_path).to eq("/_/agent/setup")

    get agent_setup_path, headers: { "Accept" => "*/*" }

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("text/markdown")
    expect(response.body).to include("# CoPlan agent setup")
    expect(response.body).to include("You are the agent receiving this guide")
    expect(response.body).to include("http://www.example.com/agent-instructions")
    expect(response.body).to include("At the start of each CoPlan task, fetch")
    expect(response.body).to include("Never use a saved copy")
    expect(response.body.length).to be < 2_000
  end

  it "includes the engine mount point in both URLs" do
    path = agent_setup_path
    get path, env: { "SCRIPT_NAME" => "/coplan" }

    expect(response.body).to include("http://www.example.com/coplan/agent-instructions")

    get path, headers: { "Accept" => browser_accept }, env: { "SCRIPT_NAME" => "/coplan" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(data-coplan--clipboard-text-value="http://www.example.com/coplan/_/agent/setup.md"))
  end

  it "includes a host-configured install command" do
    allow(CoPlan.configuration).to receive(:agent_setup_install_command).and_return("sq agents skills add coplan")

    get agent_setup_path

    expect(response.body).to include("sq agents skills add coplan")
  end

  it "renders HTML with a copyable setup URL for browsers" do
    allow(CoPlan.configuration).to receive(:agent_setup_install_command).and_return("sq agents skills add coplan")

    get agent_setup_path, headers: { "Accept" => browser_accept }

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("text/html")
    expect(response.body).to include("Connect your AI agent")
    expect(response.body).to include(%(data-coplan--clipboard-text-value="http://www.example.com/_/agent/setup.md"))
    expect(response.body).to include("Give this URL to your agent and let it set up the CoPlan skill")
    expect(response.body).to include("Curious about what your agent will read?")
    expect(response.body).to include(%(href="#{agent_instructions_reference_path}"))
    expect(response.body).not_to include("# CoPlan agent setup")
    expect(response.body).not_to include("http://www.example.com/agent-instructions")
    expect(response.body).not_to include("sq agents skills add coplan")
  end

  it "links to a reference page that renders successfully" do
    get agent_setup_path, headers: { "Accept" => browser_accept }

    link = Nokogiri::HTML(response.body).at_css("a[href='#{agent_instructions_reference_path}']")
    expect(link).not_to be_nil

    get link["href"], headers: { "Accept" => browser_accept }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("CoPlan API")
  end

  it "serves Markdown at .md even to browsers" do
    get agent_setup_path(format: :md), headers: { "Accept" => browser_accept }

    expect(response.content_type).to include("text/markdown")
    expect(response.body).to include("# CoPlan agent setup")
  end
end
