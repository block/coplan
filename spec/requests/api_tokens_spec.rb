require "rails_helper"

RSpec.describe "Settings::Tokens", type: :request do
  let(:alice) { create(:coplan_user, :admin) }

  before { sign_in_as(alice) }

  it "index shows tokens" do
    create(:api_token, user: alice)
    get settings_tokens_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include("data-table")
  end

  it "create token shows raw token" do
    expect {
      post settings_tokens_path, params: { api_token: { name: "Test Token" } }
    }.to change(CoPlan::ApiToken, :count).by(1)
    expect(response).to redirect_to(settings_tokens_path)
    follow_redirect!
    expect(response.body).to include("token-reveal")
  end

  it "create token saves token_prefix" do
    post settings_tokens_path, params: { api_token: { name: "Prefix Test" } }
    token = CoPlan::ApiToken.last
    expect(token.token_prefix).to be_present
    expect(token.token_prefix.length).to eq(8)
  end

  it "revoke token" do
    token = create(:api_token, user: alice)
    expect(token).not_to be_revoked
    delete settings_token_path(token)
    expect(response).to redirect_to(settings_tokens_path)
    token.reload
    expect(token).to be_revoked
  end

  it "requires authentication" do
    delete sign_out_path
    get settings_tokens_path
    expect(response).to redirect_to(sign_in_path)
  end
  def session_token(**attributes)
    create(:api_token, user: alice, expires_at: 1.day.from_now, **attributes)
  end

  it "keeps session churn out of settings and the personal token manager" do
    create(:api_token, user: alice, name: "Work laptop")
    session_token(name: "Visible only in session manager")
    session_token(name: "Old run", expires_at: 1.day.ago)
    get settings_root_path
    expect(response.body).to include("1 agent session", "1 personal token", "Manage agent sessions")
    expect(response.body).not_to include("Old run", "Visible only in session manager", "Create Token")
    get settings_tokens_path
    expect(response.body).to include("Work laptop", "Personal API tokens")
    expect(response.body).not_to include("Old run", "Visible only in session manager")
  end

  it "shows reported identity and effective access without exposing secrets" do
    parent = create(:api_token, user: alice, name: "Work laptop")
    token = session_token(name: "Design review", agent_name: "Claude", parent: parent,
      metadata: { harness: "claude-code", model: "test-model", harness_version: "1.2" })
    session_token(name: "Expired run", expires_at: 1.day.ago)
    session_token(name: "Revoked run", revoked_at: Time.current)
    create(:api_token, user: create(:coplan_user), name: "Someone else's run", expires_at: 1.day.from_now)
    get settings_agent_sessions_path
    expect(response.body).to include("Design review", "Claude", "claude-code", "test-model", "1.2", "Personal token: Work laptop", "Acting for")
    expect(response.body).not_to include("Expired run", "Revoked run", "Someone else", token.token_digest)
    expect(response.body).to include("Expires in", "Valid access (1)", "History (2)")
  end

  it "puts expired, revoked and parent-disabled sessions in neutral history" do
    parent = create(:api_token, user: alice, revoked_at: Time.current)
    session_token(name: "Parent disabled", parent: parent)
    session_token(name: "Expired run", expires_at: 1.day.ago)
    session_token(name: "Revoked run", revoked_at: Time.current)
    get settings_agent_sessions_path(filter: "history")
    expect(response.body).to include("Parent disabled", "Parent access ended", "Expired run", "Revoked run", "Harness not reported", "Model not reported")
    expect(response.body).not_to include('badge--warning', 'badge--danger', '>Revoke</button>')
    get settings_agent_sessions_path
    expect(response.body).to include("Valid access (0)")
    expect(response.body).not_to include("Parent disabled", "Expired run")
  end

  it "paginates history and preserves filters while searching identity fields" do
    27.times { |i| session_token(name: "Past run #{i}", expires_at: 1.day.ago, metadata: { harness: "codex", model: "test-model" }) }
    get settings_agent_sessions_path(filter: "history", q: "CODEX")
    document = Nokogiri::HTML(response.body)
    expect(document.css("#sessions-list tr").length).to eq(25)
    expect(document.at_css('a[rel="next"]')["href"]).to include("filter=history", "q=CODEX", "page=2")
    get settings_agent_sessions_path(filter: "history", q: "test-model", page: 2)
    expect(Nokogiri::HTML(response.body).css("#sessions-list tr").length).to eq(2)
    get settings_agent_sessions_path(filter: "history", q: "%")
    expect(response.body).to include("No sessions match")
  end

  it "revokes a session in place and moves it to history" do
    token = session_token(name: "Current run")
    delete settings_token_path(token), params: { surface: "sessions" }, as: :turbo_stream
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('target="agent-sessions"', "Valid access (0)", "History (1)", "Session access revoked")
    expect(token.reload).to be_revoked
    expect(response.body).not_to include("Current run")
    get settings_agent_sessions_path(filter: "history")
    expect(response.body).to include("Current run")
  end

  it "revoking a personal credential also ends its child sessions" do
    parent = create(:api_token, user: alice)
    child = session_token(parent: parent)
    delete settings_token_path(parent), as: :turbo_stream
    expect(response.body).to include('target="personal-tokens"', "Revoked")
    expect(child.reload).to be_revoked
    get settings_agent_sessions_path
    expect(response.body).to include("Valid access (0)")
  end

  it "does not revoke another person's token" do
    token = create(:api_token)
    delete settings_token_path(token), as: :turbo_stream
    expect(response).to have_http_status(:not_found)
    expect(token.reload).not_to be_revoked
  end

  it "keeps validation errors in the creation form" do
    post settings_tokens_path, params: { api_token: { name: " " } }, as: :turbo_stream
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include('target="token-errors"', "Name")
  end

  it "requires authentication for session inspection" do
    delete sign_out_path
    get settings_agent_sessions_path
    expect(response).to redirect_to(sign_in_path)
  end
end
