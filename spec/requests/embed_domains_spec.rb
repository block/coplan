require "rails_helper"
RSpec.describe "Iframe domain administration", type: :request do
  it "lets only admins approve and remove a domain" do
    sign_in_as(create(:coplan_user))
    post '/_/admin/embed_domains', params: { embed_domain: { hostname: 'embed.example.com' } }
    expect(response).to have_http_status(:forbidden)
    expect(CoPlan::EmbedDomain.count).to eq(0)
    sign_in_as(create(:coplan_user, admin: true))
    post '/_/admin/embed_domains', params: { embed_domain: { hostname: 'embed.example.com' } }
    expect(response).to have_http_status(:redirect)
    domain = CoPlan::EmbedDomain.find_by!(hostname: 'embed.example.com')
    delete "/_/admin/embed_domains/#{domain.id}"
    expect(response).to have_http_status(:redirect)
    expect(CoPlan::EmbedDomain.count).to eq(0)
  end
  it "restricts iframe destinations and composes with an existing host policy" do
    sign_in_as(create(:coplan_user))
    CoPlan::EmbedDomain.create!(hostname: 'embed.example.com')
    host_policy = ActionDispatch::ContentSecurityPolicy.new { |policy| policy.default_src :self; policy.frame_src :none }
    allow_any_instance_of(ActionDispatch::Request).to receive(:content_security_policy).and_return(host_policy)
    get settings_root_path
    expect(response.headers['Content-Security-Policy']).to include("default-src 'self'; frame-src 'none'")
    expect(response.headers['Content-Security-Policy']).to include('frame-src https://embed.example.com')
    CoPlan::EmbedDomain.delete_all
    get settings_root_path
    expect(response.headers['Content-Security-Policy']).to include("frame-src 'none'")
  end
end
