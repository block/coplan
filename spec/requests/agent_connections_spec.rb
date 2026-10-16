require "rails_helper"

RSpec.describe "Connecting a local computer", type: :request do
  let(:user) { create(:coplan_user) }
  let(:start_path) { "/api/v1/agent_connections" }
  let(:poll_path) { "/api/v1/agent_connections/token" }

  def start_connection(**options)
    post start_path, params: { name: "Work laptop" }.merge(options), as: :json
    JSON.parse(response.body)
  end

  it "starts without a credential and returns mount-aware, non-secret browser URLs" do
    post start_path, params: { name: "Work laptop" }, as: :json, env: { "SCRIPT_NAME" => "/coplan" }
    expect(response).to have_http_status(:created)
    result = JSON.parse(response.body)
    expect(result["verification_uri"]).to eq("http://www.example.com/coplan/_/agent/connect")
    expect(result["verification_uri_complete"]).to include("user_code=#{result['user_code']}")
    expect(result["verification_uri_complete"]).not_to include(result["device_code"])
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(CoPlan::ApiToken.count).to eq(0)
  end

  it "requires browser login, matching-code confirmation, and a separate private redemption secret" do
    result = start_connection
    get agent_connect_path(user_code: result["user_code"]), headers: { "Accept" => "text/html" }
    expect(response.body).to include("Sign in to approve", "Continue after signing in")
    expect(response.body).not_to include(result["device_code"])
    post agent_connect_path, params: { user_code: result["user_code"], decision: "approve", confirm_code: "1" }
    expect(response).to redirect_to(sign_in_path)

    sign_in_as(user)
    get agent_connect_path(user_code: result["user_code"]), headers: { "Accept" => "text/html" }
    expect(response.body).to include("Work laptop", user.name, "Connect this computer")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    expect(CoPlan::ApiToken.count).to eq(0)
    post agent_connect_path, params: { user_code: result["user_code"], decision: "approve" }, as: :turbo_stream
    expect(response).to have_http_status(:unprocessable_content)
    expect(CoPlan::AgentConnectionRequest.last.status).to eq("pending")
    post agent_connect_path, params: { user_code: result["user_code"], decision: "approve", confirm_code: "1" }, as: :turbo_stream
    expect(response.body).to include('target="connection-approval"', "Connection approved")
    expect(CoPlan::ApiToken.count).to eq(0)

    post poll_path, params: { device_code: result["user_code"] }, as: :json
    expect(JSON.parse(response.body)).to eq("error" => "invalid_grant")
    post poll_path, params: { device_code: result["device_code"] }, as: :json
    credential = JSON.parse(response.body).fetch("token")
    expect(CoPlan::ApiToken.authenticate(credential).user).to eq(user)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    post poll_path, params: { device_code: result["device_code"] }, as: :json
    expect(JSON.parse(response.body)).to eq("error" => "invalid_grant")
  end

  it "returns pending, slow-down, denial, expiry, and malformed-request errors" do
    result = start_connection
    post poll_path, params: { device_code: result["device_code"] }, as: :json
    expect(JSON.parse(response.body)).to eq("error" => "authorization_pending")
    post poll_path, params: { device_code: result["device_code"] }, as: :json
    expect(JSON.parse(response.body)).to eq("error" => "slow_down")
    sign_in_as(user)
    post agent_connect_path, params: { user_code: result["user_code"], decision: "deny" }, as: :turbo_stream
    expect(response.body).to include("Connection declined")
    post poll_path, params: { device_code: result["device_code"] }, as: :json
    expect(JSON.parse(response.body)).to eq("error" => "access_denied")
    travel 11.minutes
    post poll_path, params: { device_code: result["device_code"] }, as: :json
    expect(JSON.parse(response.body)).to eq("error" => "expired_token")
    post start_path, params: { name: "" }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["error"]).to eq("invalid_request")
  end

  it "does not expose an approved account to another signed-in person" do
    result = start_connection
    record = CoPlan::AgentConnectionRequest.last
    record.decide!(user: user, approve: true)
    sign_in_as(create(:coplan_user))
    get agent_connect_path(user_code: result["user_code"]), headers: { "Accept" => "text/html" }
    expect(response.body).to include("no longer available")
    expect(response.body).not_to include(user.name, "Connection approved")
  end

  it "disables bootstrap endpoints and onboarding for hosts with implicit API auth" do
    allow(CoPlan.configuration).to receive(:api_authenticate).and_return(->(_request) { nil })
    post start_path, params: { name: "Laptop" }, as: :json
    expect(response).to have_http_status(:not_found)
    post poll_path, params: { device_code: "a" * 64 }, as: :json
    expect(response).to have_http_status(:not_found)
    get agent_connect_path, headers: { "Accept" => "text/html" }
    expect(response).to have_http_status(:not_found)
    sign_in_as(user)
    get settings_root_path
    expect(response.body).not_to include("Connect your local agent")
    get agent_setup_path(format: :md)
    expect(response.body).not_to include("## Connect this computer")
  end

  it "filters the private redemption secret from Rails request logs" do
    filters = Rails.application.config.filter_parameters
    expect(ActiveSupport::ParameterFilter.new(filters).filter("device_code" => "secret", "user_code" => "public")).to eq(
      "device_code" => "[FILTERED]", "user_code" => "[FILTERED]")
  end

  it "rejects approval without a CSRF token" do
    result = start_connection
    sign_in_as(user)
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post agent_connect_path, params: { user_code: result["user_code"], decision: "approve", confirm_code: "1" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(CoPlan::AgentConnectionRequest.last.status).to eq("pending")
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
  it "rate limits public connection starts by IP" do
    memory = ActiveSupport::Cache::MemoryStore.new
    store = CoPlan::Api::V1::AgentConnectionsController.cache_store
    allow(store).to receive(:increment) { |key, amount, **options| memory.increment(key, amount, **options) }
    10.times { start_connection }
    expect(response).to have_http_status(:created)
    start_connection
    expect(response).to have_http_status(:too_many_requests)
    expect(JSON.parse(response.body)).to eq("error" => "rate_limited")
    expect(CoPlan::AgentConnectionRequest.count).to eq(10)
  end
end
