require "rails_helper"

# The plan title heads the document card and slides into the sticky nav once
# it scrolls behind the bar. A leading H1 in the content would repeat it, so
# the reading view and the outline both drop it.
RSpec.describe "Plan title on the document", type: :system do
  let(:author) { create(:coplan_user, email: "title-author@example.com") }
  let(:sections) { (1..12).map { |i| "## Section #{i}\n\n#{"Body text for this section. " * 30}" }.join("\n\n") }

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
  end

  def open_plan(content)
    plan = CoPlan::Plans::Create.call(title: "Shared workspaces", content: content, user: author,
      visibility: "published", actor_type: "human")
    sign_in(author)
    visit plan_page_path(plan)
    expect(page).to have_css("#plan-title .plan-title__heading", text: "Shared workspaces")
    plan
  end

  it "hides a leading H1 in the reading view and the outline, whatever it says" do
    open_plan("# Something else entirely\n\nIntro paragraph.\n\n#{sections}")

    expect(page).to have_css("#plan-content-body h1", text: "Something else entirely", visible: :hidden)
    expect(page).to have_css("#plan-content-body p", text: "Intro paragraph.")
    expect(page).to have_css(".content-nav__link-text", text: "Section 1")
    expect(page).to have_no_css(".content-nav__link-text", text: "Something else entirely")
  end

  it "shows a leading H1 while an open discussion is anchored in it" do
    plan = open_plan("# Something else entirely\n\nIntro paragraph.\n\n#{sections}")
    thread = create(:comment_thread, plan: plan, created_by_user: author, anchor_text: "Something else")
    thread.comments.create!(author_type: "human", author_id: author.id, body_markdown: "Is this the title?")
    visit plan_page_path(plan)

    expect(page).to have_css("#plan-content-body h1 mark.anchor-highlight--open", text: "Something else")
  end

  it "puts the update dot for the opening section on its first visible block" do
    open_plan("# Something else entirely\n\nIntro paragraph.\n\n#{sections}")
    page.execute_script(<<~JS)
      const layout = document.querySelector(".plan-layout")
      layout.setAttribute("data-coplan--changed-sections-keys-value", '["something-else-entirely"]')
      window.Stimulus.getControllerForElementAndIdentifier(layout, "coplan--changed-sections").connect()
    JS

    expect(page).to have_css("#plan-content-body p.section-updated .section-update-marker", visible: :all)
    expect(page).to have_css("#plan-content-body p.section-updated", text: "Intro paragraph.")
    expect(page).to have_no_css("#plan-content-body h1.section-updated", visible: :all)
  end

  it "acknowledges an opening-section marker even when its block is taller than the viewport" do
    open_plan("# Opening\n\n#{'Long introductory paragraph. ' * 500}\n\n#{sections}")
    page.execute_script(<<~JS)
      const layout = document.querySelector(".plan-layout")
      layout.setAttribute("data-coplan--changed-sections-keys-value", '["opening"]')
      window.Stimulus.getControllerForElementAndIdentifier(layout, "coplan--changed-sections").connect()
    JS

    expect(page).to have_css("p.section-updated .section-update-marker")
    expect(page.evaluate_script("document.querySelector('p.section-updated').getBoundingClientRect().height > window.innerHeight")).to be(true)
    expect(page).to have_css("p.section-updated--viewed", wait: 6)
  end

  it "starts the outline beside the title and keeps the title aligned with the body" do
    open_plan(sections)

    positions = page.evaluate_script(<<~JS)
      (() => {
        const title = document.querySelector("#plan-title").getBoundingClientRect()
        const outline = document.querySelector(".content-nav").getBoundingClientRect()
        const body = document.querySelector("#plan-content-body").getBoundingClientRect()
        return { topGap: Math.abs(title.top - outline.top), leftGap: Math.abs(title.left - body.left) }
      })()
    JS
    expect(positions["topGap"]).to be <= 1
    expect(positions["leftGap"]).to be <= 1
  end

  it "keeps a later H1 visible" do
    open_plan("Intro paragraph.\n\n# A real heading\n\n#{sections}")

    expect(page).to have_css("#plan-content-body h1", text: "A real heading")
    expect(page).to have_css(".content-nav__link-text", text: "A real heading")
  end

  it "moves the title into the sticky nav once it scrolls behind the bar" do
    open_plan(sections)

    expect(page).to have_no_css(".site-nav__plan-context--visible")
    page.execute_script("window.scrollTo(0, 900)")
    expect(page).to have_css(".site-nav__plan-context--visible .site-nav__doc-title-text", text: "Shared workspaces")
    page.execute_script("window.scrollTo(0, 0)")
    expect(page).to have_no_css(".site-nav__plan-context--visible")
  end
end
