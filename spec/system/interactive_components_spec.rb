require "rails_helper"

RSpec.describe "Interactive components", type: :system do
  let(:author) { create(:coplan_user, email: "components@example.com") }
  let(:source) { Coplan::Engine.root.join("db/demo/content/interactive-components.md").read }

  def tab_revealed?(actions)
    page.evaluate_script("Math.abs(arguments[0].getBoundingClientRect().top - arguments[0].parentElement.getBoundingClientRect().top) < 1", actions)
  end

  def tab_retracted?(actions)
    page.evaluate_script("arguments[0].getBoundingClientRect().bottom <= arguments[0].parentElement.getBoundingClientRect().top + 1", actions)
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  it "draws the inline SVG, runs interactive JS, and opens a component discussion" do
    plan = Coplan::Plans::Create.call(title: "Components", content: source, user: author, actor_type: "human")
    visit plan_page_path(plan)
    within_frame(find('iframe[title="Payment path"]')) do
      expect(page).to have_css("svg text", text: "Retry queue")
      expect(page.evaluate_script("document.querySelector('[nonce]')")).to be_nil
      expect(page.evaluate_script("document.querySelector('meta[http-equiv=Content-Security-Policy]').content")).to eq("script-src blob:")
      expect(page.evaluate_script("self.origin")).to eq("null")
      expect(page.evaluate_script("typeof RTCPeerConnection")).to eq("undefined")
      directive = page.evaluate_async_script(<<~JS)
        const done = arguments[0]
        document.addEventListener("securitypolicyviolation", event => done(event.effectiveDirective), {once: true})
        fetch(location.href, {mode: "no-cors"}).then(() => done("connected"), () => {})
      JS
      expect(directive).to eq("connect-src")
    end
    within_frame(find('iframe[title="Component"]')) do
      expect(page).to have_text("1 + 2 + 4 = 7 seconds")
      slider = find('input[type="range"]')
      slider.click
      slider.send_keys(:end)
      expect(page).to have_text("1 + 2 + 4 + 8 + 16 + 32 = 63 seconds")
    end
    simulator = find("figure:has(iframe[title='Component'])")
    expect(simulator).to have_no_css("figcaption, summary", visible: :all)
    simulator.hover
    simulator.find('button[aria-label="Expand component"]').click
    expect(simulator).to match_css(":popover-open")
    within_frame(simulator.find("iframe")) { expect(page).to have_text("1 + 2 + 4 + 8 + 16 + 32 = 63 seconds") }
    simulator.hover
    simulator.find('button[aria-label="Collapse component"]').click
    expect(simulator).not_to match_css(":popover-open")
    find_button("Appearance").click
    find('input[name="appearance_mode"][value="dark"]', visible: :all).ancestor("label").click
    find("body").send_keys(:escape)
    within_frame(simulator.find("iframe")) do
      expect(page).to have_css('html[style*="color-scheme: dark"]')
      expect(page).to have_text("1 + 2 + 4 + 8 + 16 + 32 = 63 seconds")
    end
    expect(page).to have_css(".document-component[data-render-ms]", count: 2)
    simulator.hover
    tab = simulator.find(".document-component__actions")
    expect(simulator).to have_css(".document-component__actions") { |actions| tab_revealed?(actions) }
    tab.find("button[data-source-target]").click
    selection = simulator.find(".document-component__selection")
    mouse = page.driver.browser.action
    mouse.move_to(selection.native, -60, -10).click_and_hold.move_by(80, 16).perform
    mark = selection.find(".document-component__mark")
    expect(page.evaluate_script("getComputedStyle(arguments[0]).backgroundColor", mark)).to eq("rgba(0, 0, 0, 0)")
    mouse.release.perform
    expect(page).to have_css(".source-comments textarea:focus", visible: true)
    expect(page).to have_css(".source-comments img[src^='blob:']", visible: true)
    find("#source-comment-body").set("Explain this retry delay.")
    find("#source-comment-body").send_keys(:escape)
    simulator.hover
    tab.find("button[data-source-target]").click
    expect(find("#source-comment-body").value).to eq("Explain this retry delay.")
    expect(page).to have_css(".source-comments img[src^='blob:']", visible: true)
    within(".source-comments") { click_button "Comment" }
    posted_image = find(".source-comments .comment__body img.component-snapshot", visible: true)
    expect(page.evaluate_async_script("arguments[0].decode().then(() => arguments[1](arguments[0].naturalWidth), () => arguments[1](0))", posted_image)).to be_positive
    comment = plan.comments.reload.sole
    expect(comment.component_selection).to include("revision" => plan.current_revision, "w" => 80, "h" => 16)
    expect(comment.component_snapshot.download).to start_with(Coplan::Comments::CanvasPng::SIGNATURE)
    visit plan_page_path(plan)
    simulator = find("figure:has(iframe[title='Component'])")
    find("#plan-title").hover
    expect(simulator).to have_css(".document-component__actions", visible: :all) { |actions| tab_retracted?(actions) }
    slot = simulator.find(".document-component__tab")
    slot.hover
    expect(simulator).to have_css(".document-component__actions") { |actions| tab_revealed?(actions) }
    expect(slot).to have_css("button[data-component-discussions]", exact_text: "1")
    diagram = find("figure:has(iframe[title='Payment path'])")
    diagram.hover
    diagram.find("button[data-source-target]").click
    diagram.find(".document-component__selection").send_keys(:enter)
    expect(page).to have_css(".source-comments img[src^='blob:']", visible: true)
    find("#source-comment-body").send_keys(:escape)
    simulator.hover
    simulator.find("button[data-source-target]").click
    simulator.find(".document-component__selection").click
    expect(page).to have_css(".source-comments textarea:focus", visible: true)
  end

  it "opens the shared comment action on selected component text and keeps the quote on the posted annotation" do
    plan = Coplan::Plans::Create.call(content: source, user: author, actor_type: "human")
    visit plan_page_path(plan)
    figure = find("figure:has(iframe[title='Payment path'])")
    frame = figure.find("iframe")
    select_label = lambda do |label = "Checkout"|
      within_frame(frame) do
        node = find("svg text", exact_text: label)
        node.click
        page.execute_script(<<~JS, node)
          const range = document.createRange(); range.selectNodeContents(arguments[0]);
          const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
        JS
      end
    end
    figure.hover
    figure.find('button[aria-label="Expand component"]').click
    select_label.call
    find(".comment-popover__action").click
    expect(figure).to match_css(":popover-open")
    expect(page).to have_css(".source-comments textarea:focus")
    expect(page).to have_css(".source-comments img[src^='blob:']", wait: 4)
    find("#source-comment-body").set("Which checkout?")
    find("#source-comment-body").send_keys(:escape)
    expect(page).to have_no_css(".source-comments:popover-open")
    select_label.call("Retry queue")
    within_frame(frame) { find("body").send_keys("c") }
    expect(page).to have_css(".source-comments:popover-open textarea:focus")
    expect(find("#source-comment-body").value).to eq("Which checkout?")
    within(".source-comments") { click_button "Comment" }
    expect(page).to have_css(".source-comments .comment__body img.component-snapshot")
    expect(plan.comments.reload.sole.body_markdown).to eq("Which checkout?")
    expect(plan.comments.sole.component_selection).to include("quote" => "Checkout", "image" => true)
    find("body").send_keys(:escape)
    select_label.call
    within_frame(frame) { find("body").send_keys("c") }
    expect(page).to have_css(".source-comments textarea:focus")
  end

  it "restores the shared action when a live update removes an expanded component" do
    plan = Coplan::Plans::Create.call(content: source, user: author, actor_type: "human")
    visit plan_page_path(plan)
    figure = find("figure:has(iframe[title='Payment path'])")
    figure.hover
    figure.find('button[aria-label="Expand component"]').click
    within_frame(figure.find("iframe")) do
      find("svg text", exact_text: "Checkout").double_click
    end
    expect(figure).to have_css(".comment-popover__action")
    page.execute_script("arguments[0].remove()", figure)
    expect(page).to have_css(".comment-popover", visible: :hidden)
    find("#plan-content-body h2", match: :first).double_click
    find(".comment-popover__action").click
    expect(page).to have_css("#new-comment-form textarea:focus")
  end

  def comment_with_delayed_image
    plan = Coplan::Plans::Create.call(content: source, user: author, actor_type: "human")
    visit plan_page_path(plan)
    page.execute_script(<<~JS)
      const decode = window.createImageBitmap.bind(window)
      window.createImageBitmap = async blob => {
        window.createImageBitmap = decode
        const bitmap = await decode(blob)
        return new Promise(resolve => { window.finishDecode = () => resolve(bitmap) })
      }
    JS
    within_frame(find("iframe[title='Payment path']")) do
      find("svg text", exact_text: "Checkout").double_click
      find("body").send_keys("c")
    end
    expect(page).to have_css(".source-comments textarea:focus")
    expect(page).to have_css(".source-comments [role=status] .visually-hidden", text: "Preparing image…", visible: :all)
    expect(page).to have_css(".source-comments blockquote", text: "Checkout")
    expect(page).to have_css("body") { page.evaluate_script("typeof window.finishDecode === 'function'") }
    plan
  end

  it "accepts typing during capture and posts once when the image arrives" do
    plan = comment_with_delayed_image
    find("#source-comment-body").send_keys("Why retry?", :enter)
    expect(page).to have_css(".source-comments [role=status]", text: "Posting when ready…")
    within(".source-comments") { click_button "Comment" }
    expect(plan.comments.reload).to be_empty
    page.execute_script("window.finishDecode()")
    expect(page).to have_css(".source-comments .comment__body img.component-snapshot")
    expect(plan.comments.reload.sole.body_markdown).to eq("Why retry?")
    expect(plan.comments.sole.component_selection).to include("quote" => "Checkout", "image" => true)
  end

  it "cancels a queued post on dismissal and keeps the image with its draft" do
    plan = comment_with_delayed_image
    find("#source-comment-body").set("Which checkout?")
    within(".source-comments") { click_button "Comment" }
    expect(page).to have_css(".source-comments [role=status]", text: "Posting when ready…")
    find("#source-comment-body").send_keys(:escape)
    simulator = find("figure:has(iframe[title='Component'])")
    simulator.hover
    simulator.find("button[data-source-target]").click
    simulator.find(".document-component__selection").click
    find("#source-comment-body").set("A different draft")
    page.execute_script("window.finishDecode()")
    expect(page).to have_no_css(".source-comments blockquote", text: "Checkout")
    expect(find("#source-comment-body").value).to eq("A different draft")
    find("#source-comment-body").send_keys(:escape)
    within_frame(find("iframe[title='Payment path']")) do
      find("svg text", exact_text: "Retry queue").double_click
      find("body").send_keys("c")
    end
    expect(page).to have_css(".source-comments img[src^='blob:']")
    expect(page).to have_css(".source-comments blockquote", text: "Checkout")
    expect(find("#source-comment-body").value).to eq("Which checkout?")
    expect(plan.comments.reload).to be_empty
  end

  it "posts the quote and bounds if image preparation times out" do
    plan = comment_with_delayed_image
    find("#source-comment-body").send_keys("Explain this step.", :enter)
    expect(page).to have_css(".source-comments .comment__body", text: "Explain this step.", wait: 6)
    comment = plan.comments.reload.sole
    expect(comment.component_selection).to include("quote" => "Checkout", "image" => false)
    expect(comment.component_selection["w"]).to be_positive
    expect(comment.component_snapshot).not_to be_attached
    page.execute_script("window.finishDecode()")
    expect(page).to have_no_css(".source-comments img[src^='blob:']")
  end

  it "keeps native C typing in a component's editable text" do
    markdown = <<~'MD'
      # Editable component

      ::: {.component}

      root.innerHTML = '<div contenteditable>Replace me</div>';

      :::
    MD
    plan = Coplan::Plans::Create.call(content: markdown, user: author, actor_type: "human")
    visit plan_page_path(plan)
    within_frame(find("figure.document-component iframe")) do
      field = find("[contenteditable]")
      field.click
      field.send_keys([ RUBY_PLATFORM.include?("darwin") ? :meta : :control, "a" ], "c")
      expect(field).to have_text("c", exact: true)
    end
    expect(page).to have_no_css(".comment-popover__action, .source-comments textarea", visible: true)
  end

  it "captures SVG fills and flags a scrolled panel whose visible contents cannot be copied" do
    markdown = <<~'MD'
      ::: {.component title="Gradient"}

      root.innerHTML = '<svg width="100%" height="80"><defs><linearGradient id="fill"><stop stop-color="#119955"/></linearGradient></defs><rect width="100%" height="80"/></svg>';
      root.querySelector("rect").setAttribute("fill", "url(" + location.href.split("#")[0] + "#fill)");

      :::

      ::: {.component title="Scrolled"}

      root.innerHTML = '<div style="height:50px;overflow:auto"><div style="height:200px">Row one</div>Row two</div>';
      root.firstElementChild.scrollTop = 100;

      :::
    MD
    plan = Coplan::Plans::Create.call(title: "Snapshot coverage", content: markdown, user: author, actor_type: "human")
    visit plan_page_path(plan)
    expect(page).to have_css(".document-component[data-render-ms]", count: 2)
    gradient = find("figure:has(iframe[title='Gradient'])")
    gradient.hover
    gradient.find("button[data-source-target]").click
    gradient.find(".document-component__selection").send_keys(:enter)
    preview = find(".source-comments img.component-snapshot")
    rgb = page.evaluate_async_script(<<~JS, preview)
      const [image, done] = arguments
      image.decode().then(() => {
        const canvas = document.createElement("canvas")
        const ctx = canvas.getContext("2d")
        ctx.drawImage(image, Math.floor(image.naturalWidth / 2), Math.floor(image.naturalHeight / 2), 1, 1, 0, 0, 1, 1)
        done(Array.from(ctx.getImageData(0, 0, 1, 1).data).slice(0, 3))
      }, () => done([]))
    JS
    expect(rgb).to eq([ 17, 153, 85 ])
    click_button "Discard annotation"
    scrolled = find("figure:has(iframe[title='Scrolled'])")
    scrolled.hover
    scrolled.find("button[data-source-target]").click
    scrolled.find(".document-component__selection").click
    expect(page).to have_css(".source-comments blockquote", text: "Image unavailable")
    expect(page).to have_no_css(".source-comments img.component-snapshot")
  end

  it "loads a host library independently and keeps markup-looking strings inside the component" do
    catalog = Coplan::ComponentCatalog.new
    catalog.library("amount@1", source: "export const cents = 250", example: "cents")
    allow(Coplan.configuration).to receive(:component_catalog).and_return(catalog)
    markdown = <<~'MD'
      # Receipt

      ::: {.component uses="amount@1" title="Amount"}

      const { cents } = await import("amount");
      root.textContent = "</script> " + cents;

      :::
    MD
    plan = Coplan::Plans::Create.call(title: "Receipt", content: markdown, user: author, actor_type: "human")
    visit plan_page_path(plan)
    within_frame(find('iframe[title="Amount"]')) { expect(page).to have_text("</script> 250") }
    expect(page).to have_no_css("figure pre, figure figcaption", visible: :all)
  end

  it "keeps repeated captions and source out of prose discussion and writing highlights" do
    markdown = "# Demo\n\n::: {.component title=\"Later passage\"}\n\nroot.textContent = 'Later passage';\n\n:::\n\nLater passage\n"
    plan = Coplan::Plans::Create.call(title: "Demo", content: markdown, user: author, actor_type: "human")
    visit plan_page_path(plan)
    find(".writing-provenance__trigger").click
    click_button "Inspect writing"
    expect(page).to have_button("Done inspecting")
    expect(page.evaluate_script(<<~JS)).to eq([ "P" ])
      [...CSS.highlights.values()].flatMap(highlight => [...highlight]).filter(range => range.toString() === "Later passage")
        .map(range => range.startContainer.parentElement.tagName)
    JS
    click_button "Done inspecting"
    paragraph = find("#plan-content-body p", exact_text: "Later passage")
    page.execute_script(<<~JS, paragraph)
      const range = document.createRange(); range.selectNodeContents(arguments[0]);
      const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
    JS
    find("body").send_keys("c")
    within("#new-comment-form") do
      fill_in "comment_thread[body_markdown]", with: "Discuss the prose."
      click_button "Comment"
    end
    expect(page).to have_no_css("#new-comment-form", visible: true)
    expect(plan.comment_threads.reload.sole.anchor_start).to eq(markdown.rindex("Later passage"))
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-content-body p mark", text: "Later passage")
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".inline-editor .ProseMirror p mark", text: "Later passage")
  end

  it "opens on the rendered component and runs edited JavaScript when Preview is chosen" do
    catalog = Coplan::ComponentCatalog.new
    catalog.library("amount@1", source: "export const cents = 250", example: "cents")
    catalog.library("currency@1", source: "export const symbol = '$'", example: "symbol")
    catalog.type("receipt", source: "export function setup() { return {} }", uses: [ "currency@1" ], bindings: [], example: "")
    allow(Coplan.configuration).to receive(:component_catalog).and_return(catalog)
    header = '::: {.component #path title="Legacy label" type="receipt"}'
    markdown = "# Components\n\n#{header}\n\nroot.textContent = 'Original';\n\n:::\n"
    plan = Coplan::Plans::Create.call(title: "Components", content: markdown, user: author, actor_type: "human")
    visit plan_edit_page_path(plan)
    block = find(".document-editor__component", wait: 20)
    within_frame(block.find("iframe")) { expect(page).to have_text("Original") }
    script_field = 'textarea[aria-label="Component JavaScript"]'
    expect(block).to have_no_css(script_field)
    block.click_button("Edit", exact: true)
    expect(block).to have_css(".document-editor__block-header select")
    expect(block).to have_no_link("Component guide", exact: false)
    block.click_button("Modules")
    expect(block).to have_unchecked_field("amount@1")
    expect(block).to have_no_field("currency@1")
    block.click_button("Modules")
    expect(block).to have_css('.document-editor__component-colors .hljs-string', text: "'Original'", wait: 15)
    token = block.find(".document-editor__component-colors .hljs-string", text: "'Original'")
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      expect(token.evaluate_script("getComputedStyle(this).color")).not_to eq(token.evaluate_script("getComputedStyle(this.parentElement).color"))
    end
    expect(block.find(script_field).value).to eq("root.textContent = 'Original';")
    expect(block).to have_no_css("iframe", visible: true)
    click_button "Raw", exact: true
    raw = find('[aria-label="Markdown source"]')
    expect(page.evaluate_script("arguments[0].textContent", raw)).to include(markdown.strip)
    click_button "Editor", exact: true

    expect(block).to have_select("Type", selected: "Receipt")
    block.click_button("Quick guide")
    expect(page).to have_css("dialog[open] h2", text: "Receipt quick guide")
    click_button "Close quick guide", enable_aria_label: true
    expect(block.find(script_field).value).to eq("root.textContent = 'Original';")
    block.select("Base", from: "Type")
    block.click_button("Modules")
    expect(block).to have_unchecked_field("currency@1")
    block.check("amount@1")
    code = 'root.textContent = "Cents " + (await import("amount")).cents;'
    block.find(script_field).set(code)
    expect(block).to have_css(".document-editor__component-colors .hljs-keyword", text: "await")
    modifier = RUBY_PLATFORM.include?("darwin") ? :meta : :control
    block.find(script_field).send_keys([ modifier, "z" ])
    expect(block).to have_css(".document-editor__component-colors .hljs-string", text: "'Original'")
    block.find(script_field).send_keys([ modifier, :shift, "z" ])
    expect(block).to have_css(".document-editor__component-colors .hljs-keyword", text: "await")
    expect(block.find("figure", visible: :all)["data-coplan--component-program-value"]).to include("Original")
    block.click_button("Preview", exact: true)
    within_frame(block.find("iframe")) { expect(page).to have_text("Cents 250") }
    click_button "Raw", exact: true
    expect(page.evaluate_script("arguments[0].textContent", raw)).to include(%(::: {.component #path title="Legacy label" uses="amount@1"}\n\n#{code}\n\n:::))
  end

  it "keeps long, scrolled JavaScript aligned and leaves oversized programs editable" do
    lines = (1..90).map { |i| "// Row #{i}" }.join("\n")
    markdown = "# Scrolling\n\n::: {.component}\n\n#{lines}\n\n:::\n"
    plan = Coplan::Plans::Create.call(title: "Scrolling", content: markdown, user: author, actor_type: "human")
    visit plan_edit_page_path(plan)
    block = find(".document-editor__component", wait: 20)
    block.click_button("Edit", exact: true)
    input = block.find('textarea[aria-label="Component JavaScript"]')
    colors = block.find(".document-editor__component-colors")
    expect(colors).to have_css(".hljs-comment", count: 90, visible: :all, wait: 15)
    page.execute_script("arguments[0].scrollTop = arguments[0].scrollHeight", input)
    expect(block).to have_css(".is-colored") {
      page.evaluate_script("arguments[0].scrollTop > 0 && arguments[0].scrollTop === arguments[1].scrollTop", input, colors)
    }
    large = "// " + "word " * 4200
    input.set(large)
    expect(block).to have_no_css(".is-colored")
    expect(input.value).to eq(large)
  end

  { "Base" => nil, "Receipt" => "receipt" }.each do |label, type|
    it "inserts #{label} with focused starter code and an in-place guide" do
      if type
        catalog = Coplan::ComponentCatalog.new
        wrapper = <<~JS
          export function setup() { return { receipt: {} } }
          export function mount({ root, receipt }) { root.textContent = "Total: " + receipt.total }
        JS
        catalog.type(type, source: wrapper, bindings: [ "receipt" ], example: "receipt.total = 250;")
        allow(Coplan.configuration).to receive(:component_catalog).and_return(catalog)
      end
      plan = Coplan::Plans::Create.call(title: "Scratchpad", content: "# Scratchpad\n\nTry it here.", user: author, actor_type: "human")
      visit plan_edit_page_path(plan)
      find(".document-editor__body .ProseMirror p", text: "Try it here.").click
      click_button "Insert content", enable_aria_label: true
      click_button "Component", exact: true
      within("[aria-label='Component types']") do
        expect(all("button").map(&:text)).to eq(type ? [ "Base", "Receipt" ] : [ "Base" ])
        click_button label, exact: true
      end
      block = find(".document-editor__component")
      starter = block.find("textarea:focus").value
      expect(block).to have_no_css("iframe", visible: :all)
      block.click_button("Quick guide")
      within("dialog[open]") do
        expect(page).to have_text("#{label} quick guide")
        expect(page).to have_text("regular browser JavaScript")
        expect(page).to have_text("root is the <main> element")
        expect(page).to have_link("DOM basics on MDN", href: Coplan::ComponentCatalog::DOM_REFERENCE_URL)
        expect(find("code").text).to eq(starter)
        click_button "Close quick guide", enable_aria_label: true
      end
      expect(block.find("textarea").value).to eq(starter)
      block.click_button("Preview", exact: true)
      within_frame(block.find("iframe")) do
        expect(find("main")).to have_text(type ? "Total: 250" : "Hello!")
      end
      click_button "Raw", exact: true
      raw = find('[aria-label="Markdown source"]')
      marker = type ? %(::: {.component type="#{type}"}) : "::: {.component}"
      expect(raw.evaluate_script("this.textContent")).to include("#{marker}\n\n#{starter}\n\n:::")
    end
  end
end
