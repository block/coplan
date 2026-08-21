require "rails_helper"

# Picking a push-to-talk key has no save button: the click is the save.
# That only works if what's lit is what the server has — a settings page
# showing a preference that never persisted is a lie you don't discover
# until the key silently doesn't work.
RSpec.describe "Push-to-talk key setting", type: :system do
  let(:user) { create(:coplan_user, email: "picker@example.com") }

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  before { sign_in(user) }

  it "saves the choice as it's clicked" do
    visit settings_root_path

    find(".segmented__option", text: "Shift").click

    Timeout.timeout(5) { sleep 0.1 until user.reload.voice_hotkey == "shift" }

    # And the page agrees with the server on the next visit.
    visit settings_root_path
    expect(page).to have_css(".segmented__option:has(input:checked)", text: "Shift")
  end

  # The macOS caveat only applies to one of the keys, so it appears the
  # moment that key is picked rather than on the next page load.
  it "explains the Ctrl+Space caveat as soon as it's picked" do
    user.update!(voice_hotkey: "shift")
    visit settings_root_path
    expect(page).to have_no_content(/switch input sources/i)

    find(".segmented__option", text: "Ctrl+Space").click

    expect(page).to have_content(/switch input sources/i)
  end

  # When the save doesn't land, the lit segment goes back to the key that
  # will actually work, and says why.
  context "when the server refuses the save" do
    before do
      page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
        const realFetch = window.fetch
        window.fetch = (url, options) =>
          String(url).includes("voice_hotkey")
            ? Promise.resolve(new Response("", { status: 500 }))
            : realFetch(url, options)
      JS
    end

    it "puts the previous key back and says it didn't save" do
      user.update!(voice_hotkey: "shift")
      visit settings_root_path

      find(".segmented__option", text: "Ctrl+Space").click

      expect(page).to have_content("Couldn't save that")
      expect(page).to have_css(".segmented__option:has(input:checked)", text: "Shift")
      # The caveat belongs to a key that isn't in force, so it goes too.
      expect(page).to have_no_content(/switch input sources/i)
      expect(user.reload.voice_hotkey).to eq("shift")
    end
  end
end
