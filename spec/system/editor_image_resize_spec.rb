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
    expect(page).to have_current_path(root_path, wait: 15)
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
      find(".document-editor__close-inline:not(:disabled)").click
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
      find(".document-editor__close-inline:not(:disabled)").click
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
    expect(page).to have_css(".document-editor__image-size", text: "64 px")
    handle.send_keys(:arrow_right)
    expect(image["width"]).to eq("74")
    expect(page).to have_css(".document-editor__image-size", text: "74 px")
    handle.send_keys(:end)
    expect(content).not_to include("width=")
    handle.send_keys(:arrow_left)
    expect(content).to include('width="')
    mod = RUBY_PLATFORM.include?("darwin") ? :meta : :control
    handle.send_keys([ mod, "z" ])
    expect(content).not_to include("width=")
    expect(page).to have_css(".document-editor__image-size", text: /\A\z/, visible: :all)
    expect(page).not_to have_css(".document-editor__image-size")
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", handle)
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/screenshots/image-resize/undo-status-#{theme}.png"))
    end
    handle.send_keys([ mod, :shift, "z" ])
    expect(content).to include('width="')
    expect(page).not_to have_css(".document-editor__image-size")
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
      find(".document-editor__close-inline:not(:disabled)").click
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

  it "pastes external thumbnails at natural size, saves that default, and keeps Undo" do
    paragraph = all(".ProseMirror p").last
    paragraph.execute_script(<<~JS)
      this.closest('[contenteditable="true"]').focus();
      const range = document.createRange(); range.selectNodeContents(this); range.collapse(false);
      window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
    JS
    page.driver.browser.action.send_keys(:enter).perform
    find(".ProseMirror").execute_script(<<~JS, image_url)
      const clipboard = new DataTransfer();
      clipboard.setData("text/html", `<p data-pm-slice="0 0 []"><img src="${arguments[0]}" alt="Pasted large image" width="293" height="293" style="width:293px;height:293px"></p>`);
      this.dispatchEvent(new ClipboardEvent("paste", { clipboardData: clipboard, bubbles: true, cancelable: true }));
    JS
    pasted = find('.ProseMirror img[alt="Pasted large image"]')
    expect(pasted.evaluate_script("this.getAttribute('width')")).to be_nil
    expect(page).to have_css('.ProseMirror img[alt="Pasted large image"]') { |el| el.evaluate_script("this.complete && this.naturalWidth > 293") }
    expect(pasted.rect.width).to be_within(1).of(pasted.evaluate_script("Math.min(this.naturalWidth, this.closest('p').clientWidth)"))
    expect(pasted.rect.width / pasted.rect.height).to be_within(0.02).of(pasted.evaluate_script("this.naturalWidth / this.naturalHeight"))
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      pasted.execute_script("this.scrollIntoView({block: 'center'})")
      page.save_screenshot(Rails.root.join("tmp/screenshots/image-paste/#{theme}.png"))
    end
    click_button "Undo"
    expect(page).not_to have_css('img[alt="Pasted large image"]')
    click_button "Redo"
    expect(page).to have_css('.ProseMirror img[alt="Pasted large image"]:not([width])')
    find(".document-editor__close-inline:not(:disabled)").click
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to include("![Pasted large image]")
    visit plan_edit_page_path(plan)
    expect(page).to have_css('.ProseMirror img[alt="Pasted large image"]:not([width])')
  end

  it "preserves intentional widths when copying images within CoPlan" do
    result = page.evaluate_async_script(<<~JS, image_url)
      const [url, done] = arguments;
      Promise.all([import("coplan/rich_document"), import("prosemirror-state")]).then(([m, state]) => {
        const first = m.createRichDocument(document.createElement("div"), `<img src="${url}" alt="Copied image" width="240">`, () => {});
        first.view.dispatch(first.view.state.tr.setSelection(new state.AllSelection(first.view.state.doc)));
        const clipboard = new DataTransfer();
        first.view.dom.dispatchEvent(new ClipboardEvent("copy", { clipboardData: clipboard, bubbles: true, cancelable: true }));
        const second = m.createRichDocument(document.createElement("div"), "", () => {});
        second.view.dom.dispatchEvent(new ClipboardEvent("paste", { clipboardData: clipboard, bubbles: true, cancelable: true }));
        const result = { copied: clipboard.getData("text/html"), pasted: second.content() };
        first.destroy(); second.destroy(); done(result);
      }).catch(error => done({ error: error.message }));
    JS
    expect(result).not_to have_key("error")
    expect(result.fetch("copied")).to include("data-coplan-image-width")
    expect(result.fetch("pasted")).to include('width="240"', "Copied image")
    expect(result.fetch("pasted")).not_to include("data-coplan-image-width")
  end

  context "with prose beside a leading image" do
    let(:image_source) { %(<img src="#{image_url}" alt="Console &amp; mockup" width="240">) }
    let(:beside) { "These words start beside the image. The paragraph wraps naturally as you keep writing about this picture." }
    let(:source) { "#{image_source} #{beside}\n\nBelow the image.\n" }

    def expect_wrapping(selector)
      layout = find(selector).evaluate_script(<<~JS)
        (() => {
          const image = this.querySelector("img").getBoundingClientRect();
          const text = [...this.childNodes].find(node => node.nodeType === Node.TEXT_NODE && node.textContent.trim());
          const range = document.createRange(); range.setStart(text, 1); range.setEnd(text, 6);
          const first = range.getBoundingClientRect();
          range.selectNodeContents(text);
          let below = this.nextElementSibling;
          while (below && !below.getClientRects().length) below = below.nextElementSibling;
          return { top: first.top - image.top, beside: first.left >= image.right + 8,
            lines: range.getClientRects().length, below: below.getBoundingClientRect().top >= image.bottom };
        })()
      JS
      expect(layout["top"]).to be_between(0, 8)
      expect(layout["beside"]).to be(true)
      expect(layout["lines"]).to be > 1
      expect(layout["below"]).to be(true)
    end

    %w[light dark].each do |theme|
      it "wraps from the top, keeps Shift+Enter beside, and moves Enter below in #{theme}" do
        page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
        expect_wrapping(".ProseMirror p.image-paragraph")
        paragraph = find(".ProseMirror p.image-paragraph")
        paragraph.execute_script(<<~JS)
          this.closest('[contenteditable="true"]').focus();
          const range = document.createRange(); range.selectNodeContents(this); range.collapse(false);
          window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
        JS
        page.driver.browser.action.key_down(:shift).send_keys(:enter).key_up(:shift).send_keys("Still beside.").perform
        expect(page).to have_css(".ProseMirror p.image-paragraph", text: "Still beside.")
        page.driver.browser.action.send_keys(:enter).send_keys("Now below.").perform
        expect(page).to have_css(".ProseMirror p:not(.image-paragraph)", text: "Now below.")
        expect_wrapping(".ProseMirror p.image-paragraph")
        page.save_screenshot(Rails.root.join("tmp/screenshots/image-wrap/editor-#{theme}.png"))
        find(".document-editor__close-inline:not(:disabled)").click
        expect(page).to have_current_path(plan_page_path(plan), wait: 15)
        expect(plan.reload.current_content).to include("Still beside.\n\nNow below.")
        expect_wrapping("#plan-content-body p.image-paragraph")
        page.save_screenshot(Rails.root.join("tmp/screenshots/image-wrap/reading-#{theme}.png"))
        visit plan_edit_page_path(plan)
        expect(page).to have_css(".ProseMirror p.image-paragraph", text: "Still beside.")
        expect_wrapping(".ProseMirror p.image-paragraph")
      end
    end

    it "updates wrapping when the leading image is deleted and restored with Undo" do
      paragraph = find(".ProseMirror p.image-paragraph")
      paragraph.execute_script(<<~JS)
        this.closest('[contenteditable="true"]').focus();
        const range = document.createRange(); range.setStart(this, 0); range.setEndAfter(this.firstChild);
        window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
      JS
      page.driver.browser.action.send_keys(:backspace).perform
      expect(page).not_to have_css(".ProseMirror p.image-paragraph")
      expect(page).to have_css(".ProseMirror p", text: beside)
      click_button "Undo"
      expect_wrapping(".ProseMirror p.image-paragraph")
    end

    it "places text below when the screen has no room beside the image" do
      image.hover
      handle.send_keys(:end)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
      expect(page).to have_css(".ProseMirror") { |el| el.evaluate_script("innerWidth === 390 && this.getBoundingClientRect().width < 390") }
      layout = image.evaluate_script(<<~JS)
        (() => {
          const image = this.getBoundingClientRect(), paragraph = this.closest("p");
          const text = [...paragraph.childNodes].find(node => node.nodeType === Node.TEXT_NODE && node.textContent.trim());
          const range = document.createRange(); range.setStart(text, 1); range.setEnd(text, 6);
          return { textTop: range.getBoundingClientRect().top, bottom: image.bottom, right: image.right, viewport: innerWidth };
        })()
      JS
      expect(layout["textTop"]).to be >= layout["bottom"]
      expect(layout["right"]).to be <= layout["viewport"]
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end

    context "when the image is linked" do
      let(:image_source) { "[#{super()}](https://example.com/full)" }

      it "wraps beside the link and can grow back to full width" do
        expect_wrapping(".ProseMirror p.image-paragraph")
        image.hover
        handle.send_keys(:end)
        expect(content).not_to include('width="')
        expect(image.rect.width).to be > 240
        expect(content).to include("](https://example.com/full)")
        find(".document-editor__close-inline:not(:disabled)").click
        expect(page).to have_current_path(plan_page_path(plan), wait: 15)
        expect(page).to have_css("p.image-paragraph .image-frame a img")
      end
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
