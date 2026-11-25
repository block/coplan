require "rails_helper"

RSpec.describe "Browser session cleanup", type: :system do
  it "clears cookies and local storage between visits across a session reset" do
    visit sign_in_path
    window_size = page.current_window.size
    page.execute_script(<<~JS)
      document.cookie = "reset_probe=present; path=/"
      localStorage.setItem("reset_probe", "present")
    JS
    expect(page.evaluate_script("document.cookie")).to include("reset_probe=present")
    expect(page.evaluate_script("localStorage.getItem('reset_probe')")).to eq("present")

    page.reset!
    visit sign_in_path

    expect(page.current_window.size).to eq(window_size)
    expect(page.evaluate_script("document.cookie")).not_to include("reset_probe=")
    expect(page.evaluate_script("localStorage.getItem('reset_probe')")).to be_nil
  end
end
