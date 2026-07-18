require "rails_helper"

RSpec.describe "Slack events" do
  include ActiveJob::TestHelper

  def signed_headers(body, secret: "secret", timestamp: Time.now.to_i)
    signature = OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{timestamp}:#{body}")
    { "CONTENT_TYPE" => "application/json", "HTTP_X_SLACK_REQUEST_TIMESTAMP" => timestamp.to_s, "HTTP_X_SLACK_SIGNATURE" => "v0=#{signature}" }
  end

  around do |example|
    config = CoPlan::Slack.configuration
    old = config.to_h
    config.signing_secret = "secret"
    config.bot_token = "token"
    config.base_url = "https://coplan.example.test"
    example.run
  ensure
    old.each { |key, value| config.public_send("#{key}=", value) }
  end

  it "returns 404 when unconfigured" do
    CoPlan::Slack.configuration.signing_secret = nil
    post "/integrations/slack/events", params: "{}", headers: {}
    expect(response).to have_http_status(:not_found)
  end

  it "verifies signatures and answers URL verification" do
    body = { type: "url_verification", challenge: "abc" }.to_json
    post "/integrations/slack/events", params: body, headers: signed_headers(body)
    expect(response.parsed_body).to eq("challenge" => "abc")

    post "/integrations/slack/events", params: body, headers: signed_headers(body, timestamp: 10.minutes.ago.to_i)
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects an invalid signature" do
    body = { type: "url_verification", challenge: "abc" }.to_json
    post "/integrations/slack/events", params: body, headers: signed_headers(body, secret: "wrong")
    expect(response).to have_http_status(:unauthorized)
  end

  it "enqueues link events with delivery metadata and acknowledges unsupported events" do
    body = { event_id: "Ev1", event: { type: "link_shared", links: [] } }.to_json
    headers = signed_headers(body).merge("HTTP_X_SLACK_RETRY_NUM" => "1", "HTTP_X_SLACK_RETRY_REASON" => "http_timeout")
    expect { post "/integrations/slack/events", params: body, headers: headers }.to have_enqueued_job(CoPlan::Slack::UnfurlJob).with(
      { "type" => "link_shared", "links" => [] },
      { "event_id" => "Ev1", "retry_num" => "1", "retry_reason" => "http_timeout" }
    )

    body = { event: { type: "reaction_added" } }.to_json
    expect { post "/integrations/slack/events", params: body, headers: signed_headers(body) }.not_to have_enqueued_job
    expect(response).to have_http_status(:ok)
  end

  it "rejects malformed JSON" do
    body = "{"
    post "/integrations/slack/events", params: body, headers: signed_headers(body)
    expect(response).to have_http_status(:bad_request)
  end
end
