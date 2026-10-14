require "rails_helper"
RSpec.describe "Api::V1::EmbedDomains", type: :request do
  it "requires a token and returns only exact hostnames in sorted order" do
    get api_v1_embed_domains_path
    expect(response).to have_http_status(:unauthorized)
    create(:api_token, user: create(:coplan_user), raw_token: 'embed-test-token')
    CoPlan::EmbedDomain.create!(hostname: 'z.example.com')
    CoPlan::EmbedDomain.create!(hostname: 'a.example.com')
    get api_v1_embed_domains_path, headers: { 'Authorization' => 'Bearer embed-test-token' }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq('hostnames' => %w[a.example.com z.example.com])
  end
end
