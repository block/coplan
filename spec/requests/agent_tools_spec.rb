require "rails_helper"

RSpec.describe "Agent tools", type: :request do
  # The scripts are the front door for a new agent: downloadable with
  # nothing but curl, no auth — same posture as /agent-instructions.
  describe "GET /agent-tools/:tool" do
    it "serves the attach script" do
      get "/agent-tools/coplan-attach"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("text/plain")
      expect(response.body).to start_with("#!/usr/bin/env ruby")
      expect(response.body).to include("--once")
    end

    it "serves the session helper the attach script requires" do
      get "/agent-tools/coplan_session.rb"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("CoPlanSession")
    end

    it "serves the bridge" do
      get "/agent-tools/coplan-bridge"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("--acp")
    end

    it "refuses anything off the whitelist" do
      get "/agent-tools/unknown-tool"

      expect(response).to have_http_status(:not_found)
    end

    it "never treats the tool name as a path" do
      get "/agent-tools/..%2F..%2Fconfig%2Froutes.rb"

      expect(response).to have_http_status(:not_found)
    end
  end
end
