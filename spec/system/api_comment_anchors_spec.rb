require "rails_helper"

RSpec.describe "API comment anchors", type: :system do
  let(:user) { create(:coplan_user, email: "anchors@example.com") }
  let(:content) do
    <<~MARKDOWN
      # API anchor examples

      Read the `response.deadline` field.

      | Component | Responsibility |
      | --- | --- |
      | Composer | Reads the `response.deadline` field. |
      | Policy | No deadline means available. |

      <!-- internal annotation -->
    MARKDOWN
  end
  let(:plan) do
    plan = create(:plan, created_by_user: user)
    version = create(:plan_version, plan: plan, revision: 2, content_markdown: content)
    plan.update!(current_plan_version: version, current_revision: 2)
    plan
  end

  def post_comment(anchor, body, occurrence: nil)
    # Exercise the actual API before reading the result in the browser.
    raw = SecureRandom.hex(20)
    create(:api_token, user: user, raw_token: raw)
    api = ActionDispatch::Integration::Session.new(Rails.application)
    api.post api_v1_plan_comments_path(plan), params: { anchor_text: anchor, anchor_occurrence: occurrence, body_markdown: body },
      headers: { "Authorization" => "Bearer #{raw}" }, as: :json
    expect(api.response.status).to eq(201), api.response.body
    CoPlan::CommentThread.find(JSON.parse(api.response.body).fetch("thread_id"))
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  [ "light", "dark" ].each do |theme|
    it "opens Markdown and plain table anchors in the #{theme} theme" do
      inline = post_comment("Read the `response.deadline` field.", "Inline code feedback")
      row = post_comment("| Composer | Reads the `response.deadline` field. |", "Table row feedback")
      cell = post_comment("No deadline means available.", "Plain cell feedback")

      visit plan_page_path(plan)
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      [ [ inline, "p" ], [ row, "td" ], [ cell, "td" ] ].each do |thread, element|
        mark = "#{element} mark[data-thread-id='comment_thread_#{thread.id}']"
        expect(page).to have_css(mark)
        first(mark).click
        expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open", text: thread.comments.first.body_markdown)
        page.send_keys(:escape)
      end
      find("#plan-general-comments summary").click
      expect(page).to have_no_css("#plan-general-comments .document-comment", visible: true)
    end
  end

  it "keeps repeated source text attached to its requested occurrence" do
    thread = post_comment("`response.deadline`", "Only the table occurrence", occurrence: 2)
    visit plan_page_path(plan, thread: thread.id)
    expect(page).to have_css("td mark[data-thread-id='comment_thread_#{thread.id}']", text: "response.deadline")
    expect(page).to have_no_css("p mark[data-thread-id='comment_thread_#{thread.id}']")
    expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open", text: "Only the table occurrence")
  end

  it "makes an unrendered source anchor discoverable, replyable, and directly linkable" do
    thread = post_comment("<!-- internal annotation -->", "Feedback on hidden source")
    visit plan_page_path(plan)
    find("#plan-general-comments summary").click
    within("#plan-general-comments") do
      expect(page).to have_content("Feedback on hidden source")
      find("button[aria-label='Open discussion']").click
    end
    within("#comment_thread_#{thread.id}_popover") do
      fill_in "Press r to reply", with: "I can reach this discussion."
      find("textarea").send_keys(:enter)
      expect(page).to have_content("I can reach this discussion.")
      click_button "Resolve"
    end
    expect(page).to have_no_css("#plan-general-comments .document-comment", visible: true)
    visit plan_page_path(plan, thread: thread.id)
    expect(page).to have_css("#comment_thread_#{thread.id}_popover:popover-open", text: "Feedback on hidden source")
    expect(page).to have_select("document-comment-filter", selected: "Resolved")
  end
end
