require "rails_helper"

# Mermaid diagrams embed a <style> sheet inside their rendered SVG. That text
# is present in textContent but never rendered, so it must stay out of the
# comment-anchor text model: an anchor carrying stylesheet text re-matches it
# on every visit, and a <mark> wrapped inside the <style> re-parents part of
# the CSS out of the sheet — the diagram loses all styling and renders as
# black shapes.
#
# These specs drive the real pipeline (Mermaid loads from the CDN pinned in
# the importmap and renders in the browser), so they need network access —
# same as CI, where the runner fetches it fresh.
RSpec.describe "Comment anchors and Mermaid diagrams", type: :system do
  let(:user) { create(:coplan_user, email: "testuser@example.com") }

  let(:plan_content) do
    <<~MARKDOWN
      # Payment Flow

      ## The diagram

      ```mermaid
      flowchart TB
          A[Gateway] -->|routes to| B[Ledger]
          B --> C[Event feed]
      ```

      The ledger records every movement.
    MARKDOWN
  end

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Diagram Plan", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: plan_content, actor_type: "human", actor_id: user.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")
  end

  # Mermaid is fetched from the CDN and renders asynchronously.
  def wait_for_diagram
    expect(page).to have_css(".mermaid-diagram svg", wait: 15)
  end

  describe "highlighting stored anchors" do
    before do
      # An anchor that carries stylesheet text — the shape of anchors captured
      # by sweeping a selection across a diagram before capture excluded
      # non-rendered text. This string appears verbatim in the <style> of
      # every Mermaid SVG and nowhere in the rendered text. Creation now
      # refuses anchors that don't resolve, so this legacy row is written
      # past validation, the way it actually exists in old data.
      poisoned = create(:comment_thread, plan: plan)
      poisoned.update_columns(anchor_text: 'font-family:"trebuchet ms"')
      create(:comment, comment_thread: poisoned, author_id: user.id)

      # A legitimate anchor on a diagram node label — marks inside rendered
      # SVG labels are supported and must keep working.
      label = create(:comment_thread, plan: plan, anchor_text: "Event feed")
      create(:comment, comment_thread: label, author_id: user.id)

      # A prose anchor whose mark signals that the post-render highlight pass
      # has completed, so the absence assertions below don't run too early.
      prose = create(:comment_thread, plan: plan, anchor_text: "records every movement")
      create(:comment, comment_thread: prose, author_id: user.id)
    end

    it "keeps marks out of the SVG stylesheet and keeps label anchors working" do
      visit plan_path(plan)
      wait_for_diagram

      # Highlights re-apply after Mermaid settles; wait for the prose and
      # label marks from that same pass before asserting absences.
      expect(page).to have_css("mark.anchor-highlight", text: "records every movement", wait: 10)
      expect(page).to have_css(".mermaid-diagram svg mark.anchor-highlight", text: "Event feed", wait: 10)

      style_state = page.evaluate_script(<<~JS)
        (() => {
          const style = document.querySelector(".mermaid-diagram svg style");
          if (!style) return { present: false };
          return {
            present: true,
            elementChildren: style.children.length,
            cssRules: style.sheet ? style.sheet.cssRules.length : 0
          };
        })()
      JS

      expect(style_state["present"]).to be(true)
      # A mark inside the <style> would appear as an element child and break
      # the sheet; an intact sheet parses to a non-empty rule list.
      expect(style_state["elementChildren"]).to eq(0)
      expect(style_state["cssRules"]).to be > 0
    end
  end

  describe "capturing a selection swept across a diagram" do
    it "excludes the SVG stylesheet from the anchor text" do
      visit plan_path(plan)
      wait_for_diagram

      page.execute_script(<<~JS)
        const content = document.querySelector('[data-coplan--text-selection-target="content"]');
        const heading = content.querySelector("h2");
        const diagram = content.querySelector(".mermaid-diagram");
        const range = document.createRange();
        range.setStart(heading.firstChild, 0);
        range.setEndAfter(diagram);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        content.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
      JS

      expect(page).to have_css(".comment-popover", visible: true, wait: 3)
      find(".comment-popover button", text: "Comment").click

      anchor_value = page.evaluate_script(
        %{document.querySelector('[name="comment_thread[anchor_text]"]').value}
      )
      expect(anchor_value).to include("The diagram")
      expect(anchor_value).to include("Gateway")
      expect(anchor_value).not_to include("font-family")
    end
  end
end
