require "rails_helper"

RSpec.describe "Canonical document title", type: :system do
  let(:author) { create(:coplan_user, email: "title-author@example.com") }
  let!(:plan) { CoPlan::Plans::Create.call(user: author, content: "# Shared workspaces\n\nFirst paragraph.\n\n## Details\n\n#{'More detail. ' * 500}", actor_type: "local_agent") }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
    visit plan_page_path(plan)
  end

  def open_editor
    within("#plan-toolbar") { click_link "Edit" }
    expect(page).to have_css(".inline-editor .ProseMirror[contenteditable='true']", wait: 20)
  end

  def select_title
    page.execute_script <<~JS
      const title = document.querySelector('.inline-editor .ProseMirror > h1:first-child')
      title.closest('[contenteditable]').focus()
      const range = document.createRange()
      range.selectNodeContents(title)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
      document.dispatchEvent(new Event('selectionchange'))
    JS
  end

  def wait_saved(title)
    expect(page).to have_css('.document-editor__close-inline[data-state="idle"]', wait: 15)
    expect(plan.reload.title).to eq(title)
  end

  it "renders one visible title with working discussion anchors and a sticky copy" do
    expect(page).to have_css("#plan-content-body h1", count: 1)
    expect(page).to have_css("#plan-title", text: "Shared workspaces")
    thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Shared workspaces")
    thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "A title discussion")
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-title mark", text: "Shared workspaces")
    page.execute_script("window.scrollTo(0, 900)")
    expect(page).to have_css(".site-nav__plan-context--visible .site-nav__doc-title-text", text: "Shared workspaces")
  end

  it "autosaves title text repeatedly but changes the URL only on Done" do
    path = plan.url_path
    open_editor
    select_title
    find('.inline-editor .ProseMirror').send_keys("First rename")
    wait_saved("First rename")
    expect(plan.url_path).to eq(path)
    select_title
    find('.inline-editor .ProseMirror').send_keys("Final rename")
    wait_saved("Final rename")
    expect(page).to have_title("Final rename — CoPlan")
    expect(plan.url_path).to eq(path)
    expect(CoPlan::UrlAlias.find_by(path: path)).to be_nil
    within("#plan-toolbar") { click_link "Done" }
    expect(page).to have_no_css(".inline-editor .ProseMirror", wait: 15)
    expect(page).to have_css("#plan-title", text: "Final rename")
    expect(plan.reload.url_path).not_to eq(path)
    expect(CoPlan::UrlAlias.rewrite(path)).to eq(plan.url_path)
  end

  it "keeps an empty title block through autosave and fills it on Done" do
    open_editor
    select_title
    find('.inline-editor .ProseMirror').send_keys(:backspace)
    wait_saved("Untitled")
    expect(page).to have_css('.inline-editor .ProseMirror > h1:first-child')
    expect(plan.current_content.lines.first.strip).to eq("#")
    within("#plan-toolbar") { click_link "Done" }
    expect(page).to have_no_css(".inline-editor .ProseMirror", wait: 15)
    expect(page).to have_css("#plan-title", text: "Untitled")
  end

  it "blocks demotion and boundary deletion while Enter moves into the body" do
    open_editor
    select_title
    expect(page).to have_css('[aria-label="Paragraph style"][disabled]', visible: :all)
    editor = find('.inline-editor .ProseMirror')
    editor.send_keys(:left, :backspace)
    expect(page).to have_css('.inline-editor .ProseMirror > h1:first-child', text: "Shared workspaces")
    select_title
    editor.send_keys(:right, :enter)
    editor.send_keys("New body paragraph")
    expect(page).to have_css('.inline-editor .ProseMirror > h1:first-child', text: "Shared workspaces")
    expect(page).to have_css('.inline-editor .ProseMirror > p', text: "New body paragraph")
  end

  it "keeps title and body in the same undo history" do
    open_editor
    select_title
    find('.inline-editor .ProseMirror').send_keys("Renamed")
    expect(page).to have_css('.inline-editor .ProseMirror > h1:first-child', text: "Renamed")
    find('.inline-editor .ProseMirror').send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "z" ])
    expect(page).to have_css('.inline-editor .ProseMirror > h1:first-child', text: "Shared workspaces")
  end
  it "keeps a title when the whole document is replaced and supports undo" do
    open_editor
    editor = find('.inline-editor .ProseMirror')
    modifier = RUBY_PLATFORM.include?("darwin") ? :meta : :control
    editor.send_keys([ modifier, "a" ], "Replacement title")
    expect(page).to have_css('.inline-editor .ProseMirror > h1:first-child', text: "Replacement title")
    editor.send_keys([ modifier, "z" ])
    expect(page).to have_css('.inline-editor .ProseMirror > h1:first-child', text: "Shared workspaces")
    expect(page).to have_css('.inline-editor .ProseMirror > p', text: "First paragraph.")
  end
end
