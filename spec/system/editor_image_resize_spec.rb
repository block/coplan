require "rails_helper"

RSpec.describe "Resizing editor images", type: :system do
  let(:author) { create(:coplan_user, email: "image-editor@example.com") }
  let(:image_source) { "![Console & mockup](#{image_url} \"A title\")" }
  let(:source) { "Before image.\n\n#{image_source}\n\nAfter image.\n" }
  let(:image_url) { CoPlan::DevelopmentSeed.demo_logo_url }
  let(:plan) { CoPlan::Plans::Create.call(title: "Image resizing", content: source, user: author, visibility: "draft", actor_type: "human") }

  before do
    require "coplan/development_seed"
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".document-editor__image img", wait: 20)
    expect(page).to have_css(".document-editor__image img") { |el| el.evaluate_script("this.complete && this.naturalWidth > 0") }
  end

  def image
    find(".document-editor__image img", match: :first)
  end

  def handle
    find(".document-editor__image-handle", visible: :all, match: :first)
  end

  def content
    page.evaluate_script('document.querySelector("textarea[name=content]").value')
  end

  def drag_by(delta, release: true)
    image.hover
    page.driver.browser.action.move_to(handle.native).click_and_hold.move_by(delta, 0).perform
    page.driver.browser.action.release.perform if release
  end

  %w[light dark].each do |theme|
    it "resizes live, saves width, and snaps back to unset in #{theme} mode" do
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      original_width = image.rect.width
      drag_by(-180, release: false)
      expect(image.rect.width).to be_within(2).of(original_width - 180)
      expect(content).to eq(source) # preview is not an edit until release
      page.driver.browser.action.release.perform
      width = image["width"].to_i
      expect(content).to include(%(width="#{width}"), "Console &amp; mockup", "A title")
      expect(content).to include("Before image.", "After image.")
      expect(image.rect.width / image.rect.height).to be_within(0.02).of(image.evaluate_script("this.naturalWidth / this.naturalHeight"))
      page.save_screenshot(Rails.root.join("tmp/screenshots/image-resize/#{theme}.png"))
      click_link "Done"
      expect(page).to have_current_path(plan_page_path(plan), wait: 15)
      expect(plan.reload.current_content).to include(%(width="#{width}"))
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".document-editor__image img[width='#{width}']", wait: 20)
      expect(image.rect.width).to be_within(1).of(width)
      drag_by((original_width - width - 5).round, release: false)
      expect(page).to have_css(".document-editor__image.is-snapped", text: "100%")
      expect(image.rect.width).to be_within(1).of(original_width)
      page.driver.browser.action.release.perform
      expect(content).not_to include("width=")
      expect(image.evaluate_script("this.getAttribute('width')")).to be_nil
      click_link "Done"
      expect(page).to have_current_path(plan_page_path(plan), wait: 15)
      expect(plan.reload.current_content).not_to include("width=")
      expect(page).not_to have_css(".document-editor__image-handle", visible: :all)
    end
  end

  it "only reveals the handle on hover/focus and cancels a drag with Escape" do
    find("h1").hover
    expect(handle.evaluate_script('getComputedStyle(this, "::before").opacity')).to eq("0")
    image.hover
    expect(page).to have_css(".document-editor__image-handle", visible: :all) { |el| el.evaluate_script('getComputedStyle(this, "::before").opacity') == "1" }
    drag_by(-160, release: false)
    page.driver.browser.action.send_keys(:escape).release.perform
    expect(content).to eq(source)
    expect(image.evaluate_script("this.getAttribute('width')")).to be_nil
    expect(page).not_to have_css(".document-editor__image.is-resizing")
    drag_by(-100, release: false)
    page.execute_script("window.dispatchEvent(new Event('blur'))")
    page.driver.browser.action.release.perform
    expect(content).to eq(source)
    expect(image.evaluate_script("this.getAttribute('width')")).to be_nil
  end

  it "makes each gesture one undo step and supports keyboard resizing" do
    drag_by(-150)
    first = content
    drag_by(-90)
    expect(content).not_to eq(first)
    click_button "Undo"
    expect(content).to eq(first)
    click_button "Undo"
    expect(content).to eq(source)
    click_button "Redo"
    expect(content).to eq(first)
    image.hover
    handle.send_keys(:home)
    expect(image["width"]).to eq("64")
    handle.send_keys(:arrow_right)
    expect(image["width"]).to eq("74")
    handle.send_keys(:end)
    expect(content).not_to include("width=")
    handle.send_keys(:arrow_left)
    expect(content).to include('width="')
    mod = RUBY_PLATFORM.include?("darwin") ? :meta : :control
    handle.send_keys([ mod, "z" ])
    expect(content).not_to include("width=")
  end

  context "with linked images in a list" do
    let(:source) { "- [#{image_source}](https://example.com/full)\n- Another item.\n\n#{image_source}\n" }

    it "changes only the grabbed image and preserves its link across reloads" do
      drag_by(-100)
      expect(page).to have_current_path(plan_edit_page_path(plan))
      images = all(".document-editor__image img")
      images.first.hover
      control = all(".document-editor__image-handle", visible: :all).first
      control.send_keys(:home)
      expect(content.scan('width="64"').length).to eq(1)
      expect(content).to include("](https://example.com/full)", "Another item.", image_source)
      click_link "Done"
      expect(page).to have_current_path(plan_page_path(plan), wait: 15)
      visit plan_edit_page_path(plan)
      expect(page).to have_css(".document-editor__image", count: 2, wait: 20)
      expect(page).to have_css("a[href='https://example.com/full'] .document-editor__image img[width='64']")
    end
  end

  context "with an existing HTML width" do
    let(:image_source) { %(<img src="#{image_url}" alt="Console &amp; mockup" title="A title" width="320">) }

    it "preserves untouched source and synchronizes a resize into Dual/Raw" do
      expect(content).to eq(source)
      expect(image.rect.width).to be_within(1).of(320)
      %w[light dark].each do |theme|
        page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
        image.hover
        page.save_screenshot(Rails.root.join("tmp/screenshots/image-resize/handle-#{theme}.png"))
      end
      click_button "Dual", exact: true
      drag_by(-80)
      expect(content).to include('width="240"')
      expect(find('[aria-label="Markdown source"]')).to have_text('width="240"')
      click_button "Raw", exact: true
      expect(find('[aria-label="Markdown source"]')).to have_text('width="240"')
      click_button "Editor", exact: true
      expect(image.rect.width).to be_within(1).of(240)
    end
  end

  it "keeps unsafe and unrelated HTML as protected source blocks" do
    result = page.evaluate_async_script(<<~'JS')
      const done = arguments[0];
      import("coplan/rich_document").then(m => {
        const sources = ['<img src="javascript:alert(1)" width="320">', '<img src="/x" onerror="alert(1)">', '<img src="/x" width="50%">', '<details><summary>More</summary>Exact HTML</details>'];
        done(sources.map(source => {
          const doc = m.parseDocument(source);
          return { exact: m.serializeDocument(doc) === source, protected: doc.firstChild.type.name === "preserved" };
        }));
      });
    JS
    expect(result).to all(eq("exact" => true, "protected" => true))
  end
end
