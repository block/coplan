require "rails_helper"

RSpec.describe "Writing provenance", type: :system do
  let(:user) { create(:coplan_user, email: "writing@example.com") }
  let(:plan) { CoPlan::Plans::Create.call(title: "Writing sources", content: "# Delivery\n\nExisting agent proposal.\n", user: user, actor_type: "local_agent", agent_name: "Claude") }

  def open_editor
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".inline-editor [contenteditable=true]")
    expect(page).to have_text("All changes saved")
  end

  it "opens details and toggles source highlights without changing document layout" do
    visit sign_in_path
    fill_in "Email", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_page_path(plan)
    top = page.evaluate_script("document.getElementById('plan-content-body').getBoundingClientRect().top")
    find(".writing-provenance__trigger").click
    expect(page).to have_text("Human written")
    expect(page).to have_text("AI written")
    click_button "Highlight sources"
    expect(page).to have_button("Hide source highlights")
    expect(page.evaluate_script("CSS.highlights.get('coplan-writing-ai').size")).to be_positive
    expect(page.evaluate_script("document.getElementById('plan-content-body').getBoundingClientRect().top")).to eq(top)
    click_button "Hide source highlights"
    expect(page.evaluate_script("CSS.highlights.has('coplan-writing-ai')")).to be(false)
    page.current_window.resize_to(390, 844)
    expect(page.evaluate_script("document.querySelector('.writing-provenance__panel').getBoundingClientRect().right <= document.documentElement.clientWidth - 8")).to be(true)
  end

  %w[rich markdown].each do |mode|
    it "records typing and paste separately in #{mode} mode and retains them after reload" do
      open_editor
      click_button "Raw", exact: true if mode == "markdown"
      # Exercise the browser's actual paste handler and keyboard input.
      surface = mode == "markdown" ? find('[aria-label="Markdown source"]') : find('[aria-label="Document body"]')
      surface.click
      surface.send_keys([ :control, :end ])
      surface.send_keys(:end, " humaninput")
      page.execute_script(<<~JS, surface)
        const clipboard = new DataTransfer()
        clipboard.setData('text/plain', ' pastedunknown')
        arguments[0].dispatchEvent(new ClipboardEvent('paste', {clipboardData: clipboard, bubbles: true, cancelable: true}))
      JS
      expect(page).to have_text("All changes saved", wait: 15)
      expect(plan.reload.current_content).to include("humaninput", "pastedunknown")
      counts = plan.writing_provenance_summary.fetch("counts")
      expect(counts.fetch("human")).to be >= 10
      expect(counts.fetch("unknown")).to be >= 13
      expect(counts.fetch("ai")).to be_positive
      before = plan.writing_provenance_summary.fetch("counts")
      visit plan_page_path(plan)
      expect(plan.reload.writing_provenance_summary.fetch("counts")).to eq(before)
    end
  end

  it "preserves pasted origins through tracker recovery, history, and Unicode edits" do
    open_editor
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0]
      import('coplan/input_origins').then(({InputOrigins}) => {
        const tracker = new InputOrigins('base ')
        tracker.record('base human', 'human')
        tracker.record('base human pasted😀', 'unknown')
        const restored = new InputOrigins(tracker.content, tracker.draft())
        const first = restored.payload()
        restored.record('base human pasted😀 typed', 'human')
        restored.payload()
        restored.record('base human pasted😀', 'history')
        done({first, undone:restored.payload(), length:restored.content.length})
      }).catch(error => done({error:error.message}))
    JS
    expect(result).not_to have_key("error")
    expect(result.fetch("first")).to eq(result.fetch("undone"))
    expect(result.fetch("first").fetch("runs").sum(&:first)).to eq(result.fetch("length"))
    expect(result.fetch("first").fetch("runs").map(&:last)).to include("human", "unknown")
  end
end
