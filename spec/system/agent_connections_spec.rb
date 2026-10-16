require "rails_helper"
require "open3"
require "tmpdir"
require "timeout"

RSpec.describe "Browser approval for a local agent", type: :system do
  let(:user) { create(:coplan_user, email: "connection-review@example.com", name: "Connection reviewer") }

  def sign_in
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
  end

  it "connects the real local helper without showing its credential and then mints a child session" do
    sign_in
    base = page.server_url
    Dir.mktmpdir do |directory|
      credentials = File.join(directory, "private/credentials.json")
      command = [ RbConfig.ruby, CoPlan::Engine.root.join("agent_tools/coplan-connect").to_s,
        "--base", base, "--name", "Work laptop", "--credentials", credentials, "--no-open" ]
      Open3.popen3(*command) do |stdin, stdout, stderr, process|
        stdin.close
        output = +""
        approval_url = Timeout.timeout(20) do
          loop do
            line = stdout.gets
            raise "Helper exited before approval: #{stderr.read}" unless line
            output << line
            break line.strip if line.start_with?("http")
          end
        end
        code = URI.decode_www_form(URI(approval_url).query).to_h.fetch("user_code")
        visit approval_url
        expect(page).to have_content(code)
        expect(page).to have_content("Work laptop")
        expect(page).to have_content(user.name)
        expect(CoPlan::ApiToken.count).to eq(0)
        page.execute_script("window.connectionMarker = 'same-page'")
        check "This matches the code shown by my local agent."
        click_button "Connect this computer"
        expect(page).to have_content("Connection approved")
        expect(page.evaluate_script("window.connectionMarker")).to eq("same-page")
        output << Timeout.timeout(20) { stdout.read }
        expect(process.value.exitstatus).to eq(0), stderr.read
        saved = JSON.parse(File.read(credentials))
        expect(File.stat(credentials).mode & 0o777).to eq(0o600)
        expect(output).not_to include(saved.fetch("token"))
        expect(page).not_to have_content(saved.fetch("token"))
        parent = CoPlan::ApiToken.authenticate(saved.fetch("token"))
        expect(parent.user).to eq(user)
        expect(parent.name).to eq("Work laptop")

        uri = URI("#{base}/api/v1/tokens")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{saved.fetch('token')}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(agent_name: "Codex", metadata: { harness: "codex" })
        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        expect(response.code).to eq("201")
        child = CoPlan::ApiToken.find(JSON.parse(response.body).fetch("id"))
        expect(child.parent).to eq(parent)
        expect(child.metadata["harness"]).to eq("codex")
        visit settings_tokens_path
        within(find("#tokens-list tr", text: "Work laptop")) { click_button "Revoke" }
        expect(page).to have_content("Personal token and its sessions revoked.")
        expect(parent.reload).to be_revoked
        expect(child.reload).to be_revoked
      ensure
        Process.kill("TERM", process.pid) if process&.alive?
      end
    end
  end

  %w[light dark].each do |theme|
    it "previews approval and declines without issuing access in #{theme} mode" do
      user.update!(theme_preference: theme)
      record, secret, code = CoPlan::AgentConnectionRequest.issue!(name: "Work laptop")
      sign_in
      visit agent_connect_path(user_code: code)
      expect(page).to have_content("Allow this computer")
      expect(page).not_to have_content(secret)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true
      page.save_screenshot(Rails.root.join("tmp/agent-connect/approval-#{theme}.png"))
      page.current_window.resize_to(390, 844)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true
      page.save_screenshot(Rails.root.join("tmp/agent-connect/approval-mobile-#{theme}.png"))
      click_button "Decline"
      expect(page).to have_content("Connection declined")
      expect(CoPlan::ApiToken.count).to eq(0)
      expect(record.reload.status).to eq("denied")
    ensure
      page.current_window.resize_to(1400, 900)
    end
  end
end
