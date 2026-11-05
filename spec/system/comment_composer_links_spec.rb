require "rails_helper"

RSpec.describe "Links in the comment composer", type: :system do
  let(:author) { create(:coplan_user, email: "links@example.com") }
  let(:plan) { create(:plan, :considering, created_by_user: author) }
  let!(:thread_record) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: author) }
  let!(:comment) { create(:comment, comment_thread: thread_record, author_id: author.id, body_markdown: "Start here") }
  let(:textarea) { find(".comment-window:popover-open textarea") }
  let(:mod) { RUBY_PLATFORM.include?("darwin") ? :meta : :control }

  before do
    allow(CoPlan::Ai).to receive(:available?).and_return(false)
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path("/links")
    visit plan_page_path(plan)
    expand_plan_section("plan-general-comments")
    within("#plan-general-comments") { click_button "Open discussion", enable_aria_label: true }
    textarea.fill_in with: "See Design Overview"
  end

  def select_text(start, finish)
    page.execute_script("arguments[0].setSelectionRange(arguments[1], arguments[2])", textarea, start, finish)
  end

  def paste(text)
    page.evaluate_script(<<~JS, textarea, text)
      (() => {
        const data = new DataTransfer()
        data.setData("text/plain", arguments[1])
        return arguments[0].dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }))
      })()
    JS
  end

  def caret
    page.evaluate_script("[arguments[0].selectionStart, arguments[0].selectionEnd]", textarea)
  end

  it "links the selection with Mod+K, undoes it, and posts it as a link" do
    select_text(4, 19)
    accept_prompt(with: "https://example.com") { textarea.send_keys([ mod, "k" ]) }
    expect(textarea.value).to eq("See [Design Overview](https://example.com)")
    textarea.send_keys([ mod, "z" ])
    expect(textarea.value).to eq("See Design Overview")
    textarea.send_keys([ mod, :shift, "z" ])
    textarea.send_keys(:enter)
    expect(page).to have_link("Design Overview", href: "https://example.com")
    expect(CoPlan::Comment.last.body_markdown).to eq("See [Design Overview](https://example.com)")
  end

  [ :keyboard, :paste ].each do |method|
    [
      [ 'Use [draft', 'https://example.com/search?q=)' ],
      [ 'design] notes', 'https://example.com/search?q=(' ],
      [ 'Path \\[draft] (notes)', 'https://example.com/search?q=\\[draft](notes)' ]
    ].each do |label, href|
      it "preserves #{label.inspect} and #{href.inspect} in a rendered #{method} link" do
        textarea.fill_in with: label
        select_text(0, label.length)
        if method == :keyboard
          accept_prompt(with: href) { textarea.send_keys([ mod, "k" ]) }
        else
          expect(paste(href)).to be(false)
        end
        textarea.send_keys(:enter)
        # CommonMark percent-encodes backslashes and brackets in destinations.
        expected_href = href.gsub("\\", "%5C").gsub("[", "%5B").gsub("]", "%5D")
        expect(page).to have_link(label, href: expected_href, exact: true)
        posted = CoPlan::Comment.order(:created_at).last
        html = Nokogiri::HTML.fragment(CoPlan::Markdown.to_html(posted.body_markdown))
        expect(html.css("a").size).to eq(1)
        expect(html.at_css("a").text).to eq(label)
        expect(html.at_css("a")["href"]).to eq(expected_href)
      end
    end
  end

  it "inserts an empty link at the caret without a selection" do
    select_text(3, 3)
    accept_prompt(with: "mailto:team@example.com") { textarea.send_keys([ mod, "k" ]) }
    expect(textarea.value).to eq("See[](mailto:team@example.com) Design Overview")
    expect(caret).to eq([ 4, 4 ])
  end

  it "leaves the draft alone when the prompt is cancelled or the URL is invalid" do
    select_text(4, 19)
    dismiss_prompt { textarea.send_keys([ mod, "k" ]) }
    accept_prompt(with: "javascript:alert(1)") { textarea.send_keys([ mod, "k" ]) }
    expect(textarea.value).to eq("See Design Overview")
  end

  it "links a selection when a URL is pasted over it and leaves other pastes alone" do
    select_text(4, 19)
    expect(paste("  https://example.com/design \n")).to be(false)
    expect(textarea.value).to eq("See [Design Overview](https://example.com/design)")

    textarea.fill_in with: "See Design Overview"
    select_text(4, 19)
    expect(paste("just some words")).to be(true)
    select_text(19, 19)
    expect(paste("https://example.com")).to be(true)
    textarea.fill_in with: "https://example.com"
    select_text(0, 19)
    expect(paste("https://example.org")).to be(true)
  end
end
