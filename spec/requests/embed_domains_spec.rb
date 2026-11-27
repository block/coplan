require "rails_helper"
RSpec.describe "Iframe domain administration", type: :request do
  it "lets only admins approve and remove a domain" do
    sign_in_as(create(:coplan_user))
    post '/_/admin/embed_domains', params: { embed_domain: { hostname: 'embed.example.com' } }
    expect(response).to have_http_status(:forbidden)
    expect(Coplan::EmbedDomain.count).to eq(0)
    sign_in_as(create(:coplan_user, admin: true))
    post '/_/admin/embed_domains', params: { embed_domain: { hostname: 'embed.example.com' } }
    expect(response).to have_http_status(:redirect)
    domain = Coplan::EmbedDomain.find_by!(hostname: 'embed.example.com')
    delete "/_/admin/embed_domains/#{domain.id}"
    expect(response).to have_http_status(:redirect)
    expect(Coplan::EmbedDomain.count).to eq(0)
  end

  describe "the frame-src policy on HTML responses" do
    frame = "http://www.example.com/_/component-frame"
    domain = "embed.example.com"
    [
      [ true,  nil,    frame ],
      [ true,  domain, "https://#{domain} #{frame}" ],
      [ false, nil,    "'none'" ],
      [ false, domain, "https://#{domain}" ]
    ].each do |enabled, hostname, expected_sources|
      it "restricts frames with components #{enabled ? 'enabled' : 'disabled'} and #{hostname || 'no embed domain'}" do
        sign_in_as(create(:coplan_user))
        allow(Coplan.configuration).to receive(:components_enabled).and_return(enabled)
        Coplan::EmbedDomain.create!(hostname:) if hostname
        host_policy = ActionDispatch::ContentSecurityPolicy.new do |policy|
          policy.default_src :self
          policy.frame_src :none
        end
        allow_any_instance_of(ActionDispatch::Request).to receive(:content_security_policy).and_return(host_policy)

        get settings_root_path

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Security-Policy"]).to eq("default-src 'self'; frame-src 'none', frame-src #{expected_sources}")
      end
    end
  end
end
