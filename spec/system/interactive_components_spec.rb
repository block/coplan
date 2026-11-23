require "rails_helper"

RSpec.describe "Interactive components", type: :system do
  let(:author) { create(:coplan_user, email: "components@example.com") }
  let(:source) { CoPlan::Engine.root.join("db/demo/content/interactive-components.md").read }

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

  it "draws the typed diagram, runs interactive JS, and opens a component discussion" do
    plan = CoPlan::Plans::Create.call(title: "Components", content: source, user: author, actor_type: "human")
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
    within_frame(find('iframe[title="Retry simulator"]')) do
      expect(page).to have_text("1 + 2 + 4 = 7 seconds")
      find('input[type="range"]').send_keys(:arrow_right)
      expect(page).to have_text("1 + 2 + 4 + 8 = 15 seconds")
    end
    simulator = find("figure:has(iframe[title='Retry simulator'])")
    expect(simulator).to have_no_css("figcaption, summary", visible: :all)
    simulator.hover
    simulator.find('button[aria-label="Expand component"]').click
    expect(simulator).to match_css(":popover-open")
    within_frame(simulator.find("iframe")) { expect(page).to have_text("1 + 2 + 4 + 8 = 15 seconds") }
    simulator.hover
    simulator.find('button[aria-label="Collapse component"]').click
    expect(simulator).not_to match_css(":popover-open")
    find_button("Appearance").click
    find('input[name="appearance_mode"][value="dark"]', visible: :all).ancestor("label").click
    find("body").send_keys(:escape)
    within_frame(simulator.find("iframe")) do
      expect(page).to have_css('html[style*="color-scheme: dark"]')
      expect(page).to have_text("1 + 2 + 4 + 8 = 15 seconds")
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
    expect(comment.component_snapshot.download).to start_with(CoPlan::Comments::ComponentAnnotation::PNG_HEADER)
    visit plan_page_path(plan)
    simulator = find("figure:has(iframe[title='Retry simulator'])")
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
    plan = CoPlan::Plans::Create.call(title: "Snapshot coverage", content: markdown, user: author, actor_type: "human")
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
    catalog = CoPlan::ComponentCatalog.new
    catalog.library("amount@1", source: "export const cents = 250", example: "cents")
    allow(CoPlan.configuration).to receive(:component_catalog).and_return(catalog)
    markdown = <<~'MD'
      # Receipt

      ::: {.component uses="amount@1" title="Amount"}

      const { cents } = await import("amount");
      root.textContent = "</script> " + cents;

      :::
    MD
    plan = CoPlan::Plans::Create.call(title: "Receipt", content: markdown, user: author, actor_type: "human")
    visit plan_page_path(plan)
    within_frame(find('iframe[title="Amount"]')) { expect(page).to have_text("</script> 250") }
    expect(page).to have_no_css("figure pre, figure figcaption", visible: :all)
  end

  it "keeps repeated captions and source out of prose discussion and writing highlights" do
    markdown = "# Demo\n\n::: {.component title=\"Later passage\"}\n\nroot.textContent = 'Later passage';\n\n:::\n\nLater passage\n"
    plan = CoPlan::Plans::Create.call(title: "Demo", content: markdown, user: author, actor_type: "human")
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

  it "keeps the script in one editable block and preserves its exact source in Raw mode" do
    plan = CoPlan::Plans::Create.call(title: "Components", content: source, user: author, actor_type: "human")
    visit plan_edit_page_path(plan)
    expect(page).to have_css('textarea[aria-label="Component Markdown"]', count: 2, wait: 20)
    input = all('textarea[aria-label="Component Markdown"]').first
    changed = input.value.sub('"Retry queue"', '"Delayed retry"')
    input.set(changed)
    click_button "Raw", exact: true
    expect(find('[aria-label="Markdown source"]')).to have_text('diagram.node("retry", "Delayed retry");')
  end
end
