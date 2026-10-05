require "rails_helper"

RSpec.describe "Agent setup", type: :system do
  it "copies the setup URL and opens the instructions reference" do
    visit agent_setup_path

    expect(page).to have_content("Give this URL to your agent and let it set up the CoPlan skill")
    expect(find(".copy-url__value")).to have_text("/_/agent/setup.md")

    click_button "Copy URL"
    expect(page).to have_button("Copied!")

    click_link "View the agent instructions"
    expect(page).to have_current_path(agent_instructions_reference_path)
    expect(page).to have_content("CoPlan for Agents")
  end
end
