require "rails_helper"

RSpec.describe "Links in the comment composer", type: :system do
  let(:author) { create(:coplan_user, email: "links@example.com") }
  let(:plan) { create(:plan, :considering, created_by_user: author) }
  let!(:thread_record) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: author) }
  let!(:comment) { create(:comment, comment_thread: thread_record, author_id: author.id, body_markdown: "Start here") }
  def textarea
    find(".comment-window:popover-open textarea")
  end
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

  def insert_link(href)
    textarea.send_keys([ mod, "k" ])
    expect(page).to have_field("Search or paste a link", focused: true)
    fill_in "Search or paste a link", with: href
    find_field("Search or paste a link").send_keys(:enter)
  end

  def caret
    page.evaluate_script("[arguments[0].selectionStart, arguments[0].selectionEnd]", textarea)
  end

  it "links the selection with Mod+K, undoes it, and posts it as a link" do
    select_text(4, 19)
    insert_link("https://example.com")
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
          insert_link(href)
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

  it "keeps the draft visible beside the link picker" do
    select_text(4, 19)
    textarea.send_keys([ mod, "k" ])
    expect(page).to have_field("Your reply", with: "See Design Overview", enable_aria_label: true)
    input = find(".comment-window:popover-open textarea")
    panel = find('[aria-label="Insert link"]')
    expect(page.evaluate_script(<<~JS, input, panel)).to be(true)
      (() => {
        const a = arguments[0].getBoundingClientRect(), b = arguments[1].getBoundingClientRect()
        return a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top
      })()
    JS
  end

  it "searches CoPlan and inserts a result without navigating or posting" do
    select_text(4, 19)
    textarea.send_keys([ mod, "k" ])
    fill_in "Search or paste a link", with: "links@example.com"
    expect(page).to have_button(author.name)
    find_field("Search or paste a link").send_keys(:arrow_down)
    find_button(author.name).send_keys(:enter)
    expect(textarea.value).to include("See [Design Overview](http")
    expect(textarea.value).to include("/links)")
    expect(thread_record.comments.count).to eq(1)
    expect(page).to have_current_path(plan_page_path(plan))
  end

  [ :keyboard, :paste ].each do |method|
    it "posts a codex URI using #{method}" do
      select_text(4, 19)
      uri = "codex://threads/abc-123"
      method == :keyboard ? insert_link(uri) : paste(uri)
      textarea.send_keys(:enter)
      expect(page).to have_link("Design Overview", href: uri)
    end
  end

  it "inserts an empty link at the caret without a selection" do
    select_text(3, 3)
    insert_link("mailto:team@example.com")
    expect(textarea.value).to eq("See[](mailto:team@example.com) Design Overview")
    expect(caret).to eq([ 4, 4 ])
  end

  it "leaves the draft alone when link insertion is cancelled or the URL is invalid" do
    select_text(4, 19)
    textarea.send_keys([ mod, "k" ])
    find_field("Search or paste a link").send_keys(:escape)
    expect(caret).to eq([ 4, 19 ])
    insert_link("javascript:alert(1)")
    expect(page).to have_text("Enter a URI such as https://… or codex://… without spaces.")
    panel = find('[aria-label="Insert link"]')
    expect(page.evaluate_script("arguments[0].scrollHeight <= arguments[0].clientHeight", panel)).to be(true)
    expect(page.evaluate_script(<<~JS, textarea, panel)).to be(true)
      (() => {
        const a = arguments[0].getBoundingClientRect(), b = arguments[1].getBoundingClientRect()
        return a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top
      })()
    JS
    click_button "Cancel link"
    expect(textarea.value).to eq("See Design Overview")
  end

  it "cancels from the keyboard without submitting or moving the composer" do
    select_text(4, 19)
    before = page.evaluate_script("document.querySelector('.comment-window:popover-open').getBoundingClientRect().toJSON()")
    textarea.send_keys([ mod, "k" ])
    fill_in "Search or paste a link", with: "https://example.com"
    find_button("Cancel link").send_keys(:enter)
    expect(textarea.value).to eq("See Design Overview")
    expect(caret).to eq([ 4, 19 ])
    expect(page).to have_field("Your reply", enable_aria_label: true, focused: true)
    after = page.evaluate_script("document.querySelector('.comment-window:popover-open').getBoundingClientRect().toJSON()")
    expect(after).to eq(before)
    expect(thread_record.comments.count).to eq(1)
  end

  it "inserts a link without posting until the author submits the reply" do
    select_text(4, 19)
    insert_link("https://example.com")
    expect(thread_record.comments.count).to eq(1)
    expect(page).to have_field("Your reply", enable_aria_label: true, focused: true)
    expect(textarea.value).to eq("See [Design Overview](https://example.com)")
  end

  it "explains a changed draft and keeps the URL instead of silently losing insertion" do
    select_text(4, 19)
    textarea.send_keys([ mod, "k" ])
    fill_in "Search or paste a link", with: "https://example.com"
    # A transcription can arrive after the author opened the link field.
    input = find(".thread-popover__reply textarea", visible: :all)
    page.execute_script("arguments[0].value = 'Arriving transcription'", input)
    click_button "Insert link"
    expect(page).to have_text("Draft changed. Cancel and reselect text.")
    expect(page).to have_field("Search or paste a link", enable_aria_label: true, with: "https://example.com")
    click_button "Cancel link"
    expect(textarea.value).to eq("Arriving transcription")
    expect(thread_record.comments.count).to eq(1)
  end

  it "links text while editing an existing comment" do
    within(".comment-window:popover-open") { click_button "Edit" }
    textarea.fill_in with: "hi"
    select_text(0, 2)
    insert_link("https://example.com/edit")
    click_button "Save changes"
    expect(page).to have_link("hi", href: "https://example.com/edit")
    expect(comment.reload.body_markdown).to eq("[hi](https://example.com/edit)")
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
