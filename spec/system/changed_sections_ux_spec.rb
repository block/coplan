require "rails_helper"

RSpec.describe "Updated section signposts", type: :system do
  let(:author) { create(:coplan_user) }
  let(:viewer) { create(:coplan_user, email: "update-reader@example.com") }
  let(:content) do
    <<~MD
      An introduction before the headings.

      ## Design

      Keep the prose easy to read.

      ```ruby
      Order.create!(context_rule_id: "rule-61")
      ```

      | Field | Purpose |
      | --- | --- |
      | Rule UID | Attribution |

      ```mermaid
      flowchart LR
        Catalog --> Order
      ```

      ## Design

      A second section with the same heading.

      ## Rollout

      Ship gradually.

      ## Testing

      Verify attribution.

      ## References

      Background reading stays unchanged.
    MD
  end
  let(:plan) do
    p = create(:plan, :published, created_by_user: author)
    p.current_plan_version.update_columns(content_markdown: content, created_at: 2.hours.ago)
    CoPlan::PlanViewer.create!(plan: p, user: viewer, last_seen_at: 1.hour.ago)
    version = create(:plan_version, plan: p, revision: 2, actor_id: author.id,
      content_markdown: content.sub("easy to read", "comfortable to read").sub("same heading", "same heading, now updated"))
    p.update!(current_plan_version: version, current_revision: 2)
    p
  end

  before do
    plan
    visit sign_in_path
    fill_in "Email address", with: viewer.email
    click_button "Sign In"
    expect(page).to have_button("Menu")
    visit plan_page_path(plan)
    expect(page).to have_css(".plan-layout")
  end

  def broadcast_section_update(keys:, revision: 3, rewritten: false, rename: false)
    page.execute_script(<<~JS)
      const body = document.getElementById('plan-content-body')
      const stream = document.createElement('turbo-stream')
      stream.setAttribute('action', 'coplan-replace-if-clean')
      stream.setAttribute('target', 'plan-content-body')
      stream.setAttribute('data-revision', '#{revision}')
      stream.setAttribute('data-section-update', JSON.stringify({by: 'Live editor', at: new Date().toISOString(), ago: 'just now', revision: #{revision}, keys: #{keys.to_json}, rewritten: #{rewritten}}))
      const template = document.createElement('template')
      template.innerHTML = body.innerHTML.replace('comfortable to read', 'a recent live revision')
      if (#{rename}) {
        const heading = template.content.querySelector('#design')
        heading.textContent = 'Approach'
        heading.removeAttribute('id')
        template.content.querySelector('.markdown-rendered').insertAdjacentHTML('beforeend', '<h2>New section</h2><p>Fresh material.</p>')
      }
      if (#{rewritten}) {
        template.content.querySelector('.markdown-rendered').innerHTML = ['Design', 'Data', 'Rollout', 'Testing'].map(title => `<h2>${title}</h2><p>Entirely new ${title} body.</p>`).join('')
      }
      stream.append(template)
      document.body.append(stream)
    JS
  end

  it "marks new and renamed sections introduced by a live edit and updates the notice count" do
    broadcast_section_update(keys: %w[approach new-section], rename: true)
    find("#approach .section-update-marker").hover
    expect(page).to have_css('#approach .section-update-marker[aria-label*="Live editor"]')
    expect(page).to have_css("#new-section.section-updated")
    expect(page).to have_css(".changed-sections-note", text: "3 sections updated since your last visit.")
    expect(page).to have_no_css("#design")
  end

  it "keeps dismissal for the same revision but shows new material from a later revision" do
    click_button "Dismiss"
    expect(page).to have_no_css(".changed-sections-note")
    broadcast_section_update(keys: %w[design], revision: 2)
    expect(page).to have_no_css(".changed-sections-note")
    expect(page).to have_no_css(".section-update-marker")
    broadcast_section_update(keys: [])
    expect(page).to have_no_css(".changed-sections-note")

    broadcast_section_update(keys: %w[design], revision: 4)
    find("#design .section-update-marker").hover
    expect(page).to have_css(".changed-sections-note", text: "2 sections updated since your last visit.")
    expect(page.evaluate_script("document.querySelector('.changed-sections-note').inert")).to be false
  end

  it "restores only the summary when a live rewrite follows dismissal" do
    click_button "Dismiss"
    broadcast_section_update(keys: [], rewritten: true)
    expect(page).to have_css(".changed-sections-note", text: "Updated throughout since your last visit.")
    expect(page).to have_no_css(".section-updated, .section-update-marker")
    expect(page.evaluate_script("document.querySelector('.changed-sections-note').inert")).to be false
  end

  it "marks only section starts and keeps rich content's own surfaces in both themes" do
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = '#{theme}'")
      expect(page).to have_css(".changed-sections-note", text: "2 sections updated since your last visit.")
      expect(page).to have_css("h2.section-updated", count: 2)
      expect(page).to have_no_css("p.section-updated, pre.section-updated, .table-wrapper.section-updated, .mermaid.section-updated")
      expect(page.evaluate_script(<<~JS)).to be true
        Array.from(document.querySelectorAll("h2.section-updated")).every(node => {
          const style = getComputedStyle(node)
          const marker = node.querySelector('.section-update-marker')
          const target = getComputedStyle(marker)
          const dot = getComputedStyle(marker, '::before')
          return style.backgroundColor === "rgba(0, 0, 0, 0)" && style.boxShadow === "none" && style.paddingLeft === "0px" &&
            target.position === "absolute" && parseFloat(target.width) >= 22 && parseFloat(target.height) >= 22 &&
            dot.content === '\"\"' && dot.width === "5px"
        })
      JS
      # The signpost must not become part of heading text, copied content,
      # or the slug used by the outline and duplicate heading matching.
      expect(page).to have_css(".content-nav__link-text", text: "Design", count: 2)
    end
  end

  it "clears a viewed marker without shifting headings, and dismisses without moving content" do
    expect(page).to have_no_button("Review updates ↓")
    expect(page).to have_no_button("Next ↓")
    marker = find("#design .section-update-marker")
    marker.hover
    top = page.evaluate_script("document.getElementById('plan-content-body').getBoundingClientRect().top + window.scrollY")
    height = find("#design").native.rect.height
    find_button("Menu").hover
    expect(page).to have_css("#design.section-updated--viewed", wait: 5)
    expect(page).to have_no_css("#design .section-update-marker")
    expect(find("#design").native.rect.height).to eq(height)

    click_button "Dismiss"
    expect(page).to have_no_css(".section-update-marker")
    expect(page).to have_no_css(".changed-sections-note")
    page.execute_script(<<~JS)
      const layout = document.querySelector('.plan-layout')
      window.Stimulus.getControllerForElementAndIdentifier(layout, 'coplan--changed-sections').connect()
    JS
    expect(page).to have_no_css(".section-update-marker")
    expect(page).to have_no_css(".changed-sections-note")
    expect(page.evaluate_script("document.getElementById('plan-content-body').getBoundingClientRect().top + window.scrollY")).to eq(top)
  end

  it "shows attribution on hover or focus and keeps the marker while either is active" do
    marker = find("#design .section-update-marker")
    marker.hover
    expect(marker["aria-label"]).to include("Updated by #{author.name}", "ago")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#design .section-update-marker'), '::after').visibility")).to eq("visible")
    # Wait past the read delay: hovering must keep metadata available.
    sleep 3.2
    expect(page).to have_no_css("#design.section-updated--viewed")
    page.execute_script("document.querySelector('#design .section-update-marker').focus()")
    find_button("Menu").hover
    sleep 3.2
    expect(page).to have_no_css("#design.section-updated--viewed")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#design .section-update-marker'), '::after').visibility")).to eq("visible")
    page.execute_script("document.activeElement.blur()")
    expect(page).to have_css("#design.section-updated--viewed", wait: 5)
  end

  it "does not count a quick scroll past as viewing a section" do
    page.execute_script("document.getElementById('design').scrollIntoView({block: 'center'})")
    page.execute_script("document.getElementById('references').scrollIntoView({block: 'start'})")
    sleep 3.2
    expect(page).to have_no_css("#design.section-updated--viewed")
    page.execute_script("document.getElementById('design').scrollIntoView({block: 'center'})")
    expect(page).to have_css("#design.section-updated--viewed", wait: 5)
  end

  it "summarizes widespread changes once and offers history instead of marking the whole page" do
    rewritten = content.scan(/^## (.+)$/).map { |heading| "## #{heading.first}\n\nEntirely new section body.\n" }.join("\n")
    version = create(:plan_version, plan: plan, revision: 3, actor_id: author.id, content_markdown: rewritten)
    plan.update!(current_plan_version: version, current_revision: 3)
    CoPlan::PlanViewer.find_by!(plan: plan, user: viewer).update!(last_seen_at: 1.hour.ago)
    visit plan_page_path(plan)
    expect(page).to have_css(".changed-sections-note", text: "Updated throughout since your last visit.")
    expect(page).to have_no_css(".section-updated")
    within(".changed-sections-note") { click_link "History" }
    expect(page).to have_current_path(plan_history_page_path(plan))
  end

  it "keeps metadata readable on a narrow screen without overflow" do
    window = page.current_window
    original_size = window.size
    window.resize_to(390, 844)
    find("#design .section-update-marker").hover
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#design .section-update-marker'), '::after').visibility")).to eq("visible")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true
  ensure
    window.resize_to(*original_size) if original_size
  end

  it "reapplies signposts after a live content swap and remembers viewed sections" do
    expect(page).to have_css("#design.section-updated--viewed", wait: 5)
    page.execute_script(<<~JS)
      const body = document.getElementById('plan-content-body')
      body.innerHTML = body.innerHTML.replace('comfortable to read', 'pleasant to read')
      body.dispatchEvent(new CustomEvent('coplan:content-updated', { bubbles: true }))
    JS
    expect(page).to have_css("h2.section-updated", count: 2)
    expect(page).to have_css("#design.section-updated--viewed")
    expect(page).to have_css(".changed-sections-note", count: 1)
  end

  %w[local remote].each do |source|
    it "shows a fresh dot for a later #{source} edit, but not for the same edit twice" do
      expect(page).to have_css("#design.section-updated--viewed", wait: 5)
      page.execute_script(<<~JS)
        const layout = document.querySelector('.plan-layout')
        const body = document.getElementById('plan-content-body')
        const updates = JSON.parse(layout.getAttribute('data-coplan--changed-sections-updates-value'))
        if ('#{source}' === 'local') body.setAttribute('data-coplan--live-update-revision-value', '3')
        const stream = document.createElement('turbo-stream')
        stream.setAttribute('action', 'coplan-replace-if-clean')
        stream.setAttribute('target', 'plan-content-body')
        stream.setAttribute('data-revision', '3')
        // Keep the timestamp identical to the earlier edit to test revision identity.
        stream.setAttribute('data-section-update', JSON.stringify({...updates.design, by: 'Later editor', revision: 3, keys: ['design']}))
        const template = document.createElement('template')
        template.innerHTML = body.innerHTML.replace('comfortable to read', 'a later design')
        stream.append(template)
        document.body.append(stream)
      JS
      marker = find('#design:not(.section-updated--viewed) .section-update-marker[aria-label*="Later editor"]')
      marker.hover
      expect(marker["aria-label"]).to include("Later editor")
      find_button("Menu").hover
      expect(page).to have_css("#design.section-updated--viewed", wait: 5)

      # A reconnect or repeat delivery of this revision must preserve its acknowledgement.
      page.execute_script(<<~JS)
        const layout = document.querySelector('.plan-layout')
        const updates = JSON.parse(layout.getAttribute('data-coplan--changed-sections-updates-value'))
        document.getElementById('plan-content-body').dispatchEvent(new CustomEvent('coplan:section-update', {
          bubbles: true, detail: {keys: ['design'], update: updates.design}
        }))
      JS
      expect(page).to have_css("#design.section-updated--viewed")
      expect(page).to have_no_css("#design .section-update-marker")
    end
  end

  [ 2, 3 ].each do |incoming_revision|
    it "refreshes attribution at revision #{incoming_revision}, including a body already installed by a local save" do
      find("#design .section-update-marker").hover
      page.execute_script(<<~JS)
        const body = document.getElementById('plan-content-body')
        const stream = document.createElement('turbo-stream')
        stream.setAttribute('action', 'coplan-replace-if-clean')
        stream.setAttribute('target', 'plan-content-body')
        stream.setAttribute('data-revision', '#{incoming_revision}')
        stream.setAttribute('data-changed-sections', JSON.stringify({keys: ['design']}))
        stream.setAttribute('data-section-update', JSON.stringify({by: 'Another editor', at: new Date().toISOString(), ago: 'less than a minute ago', revision: #{incoming_revision}, keys: ['design']}))
        const template = document.createElement('template')
        template.innerHTML = body.innerHTML.replace('comfortable to read', 'newly updated')
        stream.append(template)
        document.body.append(stream)
      JS
      expect(page).to have_css('#design .section-update-marker[aria-label*="Another editor"]')
      expected_body = incoming_revision == 2 ? "comfortable to read" : "newly updated"
      expect(page).to have_css('#plan-content-body', text: expected_body, wait: 5)
    end
  end

  it "marks an unheaded introduction once and survives reconnecting without duplicating notices" do
    page.execute_script(<<~JS)
      const layout = document.querySelector('.plan-layout')
      layout.setAttribute('data-coplan--changed-sections-keys-value', '["__top__"]')
      const controller = window.Stimulus.getControllerForElementAndIdentifier(layout, 'coplan--changed-sections')
      controller.connect()
      controller.connect()
    JS
    expect(page).to have_css("p.section-updated", text: "An introduction", count: 1)
    expect(page).to have_css(".changed-sections-note", count: 1)
    expect(page).to have_css("p.section-updated--viewed", wait: 5)
  end
end
