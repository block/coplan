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
      expect(page.evaluate_script("self.origin")).to eq("null")
      expect(page.evaluate_async_script("const done = arguments[0]; fetch(location.href).then(() => done('connected'), () => done('blocked'))")).to eq("blocked")
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
