require "rails_helper"
require "base64"

RSpec.describe "Uploading files in the rich editor", type: :system do
  let(:author) { create(:coplan_user, email: "drop-editor@example.com") }
  let(:source) { "# Drop uploads\n\nBefore upload.\n\nKeep writing here.\n" }
  let(:plan) { CoPlan::Plans::Create.call(title: "Drop uploads", content: source, user: author, visibility: "draft", actor_type: "human") }

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path, wait: 15)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".ProseMirror p", text: "Before upload.", wait: 20)
  end

  def transfer_files(*names, paste: false)
    files = names.map do |name|
      path = name == "sample.png" ? Rails.root.join("engine/app/assets/images/coplan/coplan-logo-sm.png") : Rails.root.join("spec/fixtures/files", name)
      { name: name, data: Base64.strict_encode64(File.binread(path)),
        type: { "sample.png" => "image/png", "sample.txt" => "text/plain", "sample.html" => "text/html" }.fetch(name) }
    end
    page.execute_script(<<~JS, files, paste)
      const transfer = new DataTransfer();
      for (const file of arguments[0]) transfer.items.add(new File([Uint8Array.from(atob(file.data), c => c.charCodeAt(0))], file.name, { type: file.type }));
      const editor = document.querySelector('.document-editor__body .ProseMirror');
      const paragraph = editor.querySelector('p') || editor.querySelector('h1');
      paragraph.scrollIntoView({ block: 'center' });
      const rect = paragraph.getBoundingClientRect();
      if (arguments[1]) {
        editor.focus();
        const range = document.createRange(); range.selectNodeContents(paragraph); range.collapse(false);
        window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
        paragraph.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
        editor.dispatchEvent(new ClipboardEvent('paste', { clipboardData: transfer, bubbles: true, cancelable: true }));
      } else {
        paragraph.dispatchEvent(new DragEvent('dragover', { dataTransfer: transfer, bubbles: true, cancelable: true }));
        window.dropWasHighlighted = editor.classList.contains('is-file-drop-target');
        paragraph.dispatchEvent(new DragEvent('drop', { dataTransfer: transfer, clientX: rect.left + 4, clientY: rect.top + rect.height / 2, bubbles: true, cancelable: true }));
      }
    JS
  end

  def content
    page.evaluate_script('document.querySelector("textarea[name=content]").value')
  end

  def hold_upload
    page.execute_script(<<~JS)
      const original = window.fetch;
      window.uploadGate = new Promise(resolve => window.releaseUpload = resolve);
      window.fetch = async function(url, options) {
        if (String(url).endsWith('/attachments') && options?.method === 'POST') await window.uploadGate;
        return original.apply(this, arguments);
      };
    JS
  end

  def hold_save
    page.execute_script(<<~JS)
      const original = window.fetch;
      let held = false;
      window.saveGate = new Promise(resolve => window.releaseSave = resolve);
      window.fetch = async function(url, options) {
        if (options?.method === 'PATCH' && !held) { held = true; await window.saveGate; }
        return original.apply(this, arguments);
      };
    JS
  end

  %w[light dark].product(%w[done navigation]).each do |theme, exit_path|
    it "waits for files added after leaving starts through #{exit_path} in #{theme}" do
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      hold_save
      hold_upload
      paragraph = find(".ProseMirror p", text: "Before upload.")
      paragraph.click
      paragraph.send_keys(:end, " Saved before leaving.")
      if exit_path == "done"
        click_link "Done"
        destination = plan_page_path(plan)
      else
        location = find('a[aria-label^="Up to "]')
        destination = URI.parse(location[:href]).request_uri
        location.click
      end
      expect(page).to have_css('.document-editor__close-inline[data-state="saving"]')
      transfer_files("sample.png", paste: exit_path == "navigation")
      expect(page).to have_css(".document-editor__upload-placeholder")
      page.execute_script("window.releaseSave()")
      expect(page).not_to have_css('.document-editor__close-inline[data-state="saving"]')
      expect(page).to have_css(".document-editor__upload-placeholder")
      expect(page).to have_css(".document-editor")
      page.save_screenshot(Rails.root.join("tmp/screenshots/editor-uploads/late-#{exit_path}-#{theme}.png"))

      page.execute_script("window.releaseUpload()")
      expect(page).not_to have_css(".document-editor", wait: 20)
      expect(page).to have_current_path(destination)
      expect(plan.reload.current_content).to include("Saved before leaving.", "![sample.png]")
      expect(plan.attachments.count).to eq(1)
    end
  end

  %w[light dark].each do |theme|
    it "reuses dropped files while inserting another embed in #{theme}" do
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      transfer_files("sample.png", "sample.txt")
      expect(page).to have_css('.ProseMirror img[alt="sample.png"]', count: 1)
      original_url = find('.ProseMirror img[alt="sample.png"]')["src"]
      transfer_files("sample.png", "sample.txt")
      expect(page).to have_css('.ProseMirror img[alt="sample.png"]', count: 2)
      expect(page).to have_css('.ProseMirror a', text: "sample.txt", count: 2)
      expect(page).to have_css(".document-editor__upload-notice", text: "2 existing files reused.")
      expect(all('.ProseMirror img[alt="sample.png"]').map { |image| image["src"] }.uniq).to eq([ original_url ])
      expect(plan.attachments.count).to eq(2)
      expect(plan.plan_events.where(event_type: "attachment_added").count).to eq(2)
      page.save_screenshot(Rails.root.join("tmp/screenshots/editor-uploads/reused-#{theme}.png"))
      find(".document-editor__close-inline:not(:disabled)").click
      expect(page).to have_current_path(plan_page_path(plan), wait: 15)
      expect(plan.reload.current_content.scan("![sample.png]").size).to eq(2)
      expect(page).to have_css('#plan-content-body img[alt="sample.png"]', count: 2)
    end

    it "embeds dropped images and files, supports undo, and persists in #{theme}" do
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      hold_upload
      transfer_files("sample.png", "sample.txt")
      expect(page.evaluate_script("window.dropWasHighlighted")).to be(true)
      expect(page).not_to have_css(".ProseMirror.is-file-drop-target")
      expect(page).to have_css(".document-editor__upload-placeholder", text: "sample.png, sample.txt")
      expect(content).to eq(source)
      page.save_screenshot(Rails.root.join("tmp/screenshots/editor-uploads/pending-#{theme}.png"))
      page.execute_script("window.releaseUpload()")
      expect(page).to have_css('.ProseMirror img[alt="sample.png"]')
      expect(page).to have_css('.ProseMirror a[href*="disposition=attachment"]', text: "sample.txt")
      expect(page).not_to have_css(".document-editor__upload-placeholder")
      click_button "Undo"
      expect(page).not_to have_css('.ProseMirror img[alt="sample.png"]')
      expect(page).not_to have_css('.ProseMirror a', text: "sample.txt")
      click_button "Redo"
      expect(page).to have_css('.ProseMirror img[alt="sample.png"]')
      page.save_screenshot(Rails.root.join("tmp/screenshots/editor-uploads/embedded-#{theme}.png"))
      find(".document-editor__close-inline:not(:disabled)").click
      expect(page).to have_current_path(plan_page_path(plan), wait: 15)
      expect(page).to have_css('#plan-content-body img[alt="sample.png"]')
      expect(plan.reload.current_content).to include("![sample.png]", "[sample.txt]", "Before upload.")
      expect(plan.attachments.count).to eq(2)
      visit plan_edit_page_path(plan)
      expect(page).to have_css('.ProseMirror img[alt="sample.png"]', wait: 20)
    end
  end

  it "maps the drop point through continued typing and waits for uploads on Done" do
    hold_upload
    transfer_files("sample.png")
    expect(page).to have_css(".document-editor__upload-placeholder")
    title = find(".ProseMirror h1")
    title.click
    title.send_keys(:end, " with edits")
    expect(content).to include("# Drop uploads with edits")
    paragraph = find(".ProseMirror p", text: "Keep writing here.")
    paragraph.click
    paragraph.send_keys(:end, " Still writing.")
    expect(content).to include("Still writing.")
    find(".document-editor__close-inline:not(:disabled)").click
    expect(page).to have_css(".document-editor__upload-placeholder")
    page.execute_script("window.releaseUpload()")
    expect(page).not_to have_css(".document-editor", wait: 20)
    expect(plan.reload.current_content).to include("![sample.png]", "Still writing.")
    expect(plan.title).to eq("Drop uploads with edits")
    expect(page).to have_current_path(plan_page_path(plan))
    expect(plan.current_content.index("![sample.png]")).to be < plan.current_content.index("Keep writing here.")
  end

  it "keeps successful files from a mixed drop and lets rejected files be retried" do
    transfer_files("sample.html", "sample.txt")
    expect(page).to have_css('.ProseMirror a', text: "sample.txt")
    expect(page).to have_css('[role="alert"].document-editor__upload-notice', text: /sample.html.*not allowed/)
    expect(content).not_to include("sample.html")
    expect(page).not_to have_css(".document-editor__upload-placeholder")
    transfer_files("sample.png")
    expect(page).to have_css('.ProseMirror img[alt="sample.png"]')
  end

  it "retains the document on a network failure and accepts another drop" do
    page.execute_script(<<~JS)
      const original = window.fetch;
      window.fetch = function(url, options) {
        if (String(url).endsWith('/attachments')) { window.fetch = original; return Promise.reject(new Error('Offline')); }
        return original.apply(this, arguments);
      };
    JS
    transfer_files("sample.png")
    expect(page).to have_css('[role="alert"].document-editor__upload-notice', text: "Offline")
    expect(page).not_to have_css(".document-editor__upload-placeholder")
    expect(content).to eq(source)
    transfer_files("sample.png")
    expect(page).to have_css('.ProseMirror img[alt="sample.png"]')
  end

  it "uploads pasted image files" do
    transfer_files("sample.png", paste: true)
    expect(page).to have_css('.ProseMirror img[alt="sample.png"]')
    expect(plan.attachments.count).to eq(1)
  end

  it "synchronizes dropped files into Markdown in Dual mode" do
    click_button "Dual", exact: true
    transfer_files("sample.png", "sample.txt")
    expect(page).to have_css('.ProseMirror img[alt="sample.png"]')
    expect(find('[aria-label="Markdown source"]')).to have_text("![sample.png]")
    expect(find('[aria-label="Markdown source"]')).to have_text("[sample.txt]")
    click_button "Raw", exact: true
    expect(find('[aria-label="Markdown source"]')).to have_text("![sample.png]")
    click_button "Editor", exact: true
    expect(page).to have_css('.ProseMirror img[alt="sample.png"]')
    expect(plan.attachments.count).to eq(2)
  end

  it "creates an unsaved document before uploading its first file" do
    visit new_plan_path
    expect(page).to have_css(".ProseMirror", wait: 20)
    transfer_files("sample.png")
    expect(page).to have_css('.ProseMirror img[alt="sample.png"]', wait: 20)
    find(".document-editor__close-inline:not(:disabled)").click
    expect(page).not_to have_css(".document-editor")
    created = CoPlan::Plan.where(created_by_user: author).order(created_at: :desc).first
    expect(created).not_to eq(plan)
    expect(created.current_content).to include("![sample.png]")
    expect(created.attachments.count).to eq(1)
  end
end
