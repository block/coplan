require "rails_helper"

RSpec.describe "Interactive components", type: :system do
  let(:author) { create(:coplan_user, email: "components@example.com") }
  let(:source) { CoPlan::Engine.root.join("db/demo/content/interactive-components.md").read }

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
    expect(page).to have_css(".document-component[data-render-ms]", count: 2)
    find("figure", text: "Payment path", match: :first).find("button[data-source-target]").click
    expect(page).to have_css(".source-comments textarea:focus", visible: true)
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
    find("figure summary", text: "Source").click
    expect(page).to have_css("figure pre", text: 'root.textContent = "</script> " + cents;')
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
