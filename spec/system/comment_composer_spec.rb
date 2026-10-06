require "rails_helper"

RSpec.describe "Glass comment composer", type: :system do
  let(:author) { create(:coplan_user, email: "composer@example.com") }
  let(:plan) { create(:plan, :considering, created_by_user: author) }
  let!(:thread_record) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: author) }
  let!(:comment) { create(:comment, comment_thread: thread_record, author_id: author.id, body_markdown: "A thought worth refining") }

  before do
    allow(CoPlan::Ai).to receive(:available?).and_return(false)
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path("/composer")
    visit plan_page_path(plan)
    find("#plan-general-comments button").click
    expect(page).to have_css(".thread-popover", visible: true)
  end

  [ "reply", "new comment" ].each do |surface|
    it "keeps a failed #{surface} draft and lets Enter retry when the server returns" do
      if surface == "new comment"
        page.driver.browser.action.send_keys(:escape).perform
        page.execute_script <<~JS
          const p = document.querySelector('[data-coplan--text-selection-target="content"] p');
          const range = document.createRange(); range.selectNodeContents(p);
          const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
          p.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
        JS
        page.driver.browser.action.send_keys("c").perform
      end
      panel = find(".comment-window:popover-open")
      textarea = panel.find("textarea")
      draft = "Keep this #{surface} through a connection failure"
      textarea.fill_in with: draft
      page.execute_script <<~JS
        const originalFetch = window.fetch;
        window.fetch = (url, options) => {
          if (options?.method?.toUpperCase() === "POST") {
            window.fetch = originalFetch;
            return Promise.reject(new TypeError("Failed to fetch"));
          }
          return originalFetch(url, options);
        };
      JS
      textarea.send_keys(:enter)
      expect(panel).to have_css('[role="alert"]', text: "Couldn't reach the server. Your draft is still here.")
      expect(panel).to have_button("Try again", disabled: false)
      expect(panel).to have_css("button[type='submit']") { |button| button.rect.y + button.rect.height <= page.evaluate_script("window.innerHeight + window.scrollY") }
      expect(textarea.value).to eq(draft)
      expect(CoPlan::Comment.where(body_markdown: draft)).not_to exist
      if surface == "reply"
        [ "light", "dark" ].each do |theme|
          page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
          page.save_screenshot(Rails.root.join("tmp/composer-preview/post-failed-#{theme}.png"))
        end
      end
      textarea.send_keys(:enter)
      expect(page).to have_no_text("Couldn't reach the server")
      expect(CoPlan::Comment.where(body_markdown: draft).count).to eq(1)
    end
  end

  it "keeps an HTML server error inside the reply form instead of replacing the page" do
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: "Preserve this draft on a server error"
    page.execute_script <<~JS
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (options?.method?.toUpperCase() === "POST") {
          window.fetch = originalFetch;
          return Promise.resolve(new Response("<h1>Service unavailable</h1>", {
            status: 503, headers: { "Content-Type": "text/html" }
          }));
        }
        return originalFetch(url, options);
      };
    JS
    panel.click_button "Reply"
    expect(panel).to have_css('[role="alert"]', text: "Couldn't post your comment. Your draft is still here.")
    expect(panel.find("textarea").value).to eq("Preserve this draft on a server error")
    expect(panel).to have_button("Try again", disabled: false)
    expect(page).to have_css("#plan-header", text: plan.title)
  end

  it "aligns Edit and Delete on the same row" do
    panel = find(".comment-window:popover-open")
    edit = panel.find_button("Edit", exact: true).rect
    delete = panel.find_button("Delete", exact: true).rect
    expect(edit.y).to be_within(1).of(delete.y)
    expect(edit.height).to eq(delete.height)
  end

  [ false, true ].each do |resized|
    it "grows a #{resized ? 'resized' : 'normal'} reply while typing and follows the latest line at the screen limit" do
      panel = find(".comment-window:popover-open")
      panel.find("[aria-label='Resize comment window']").send_keys(:right) if resized
      input = panel.find("textarea")
      before = input.rect.height
      window_before = panel.rect.height
      scroll = page.evaluate_script("window.scrollY")
      input.fill_in with: (1..9).map { |n| "Reply line #{n}" }.join("\n")
      expect(input.rect.height).to be > before + 70
      expect(panel.rect.height).to be > window_before
      expect(input.evaluate_script("this.scrollHeight - this.clientHeight")).to be <= 2
      input.fill_in with: (1..80).map { |n| "A longer reply line #{n}" }.join("\n")
      expect(input.evaluate_script("this.scrollHeight - this.clientHeight - this.scrollTop")).to be <= 2
      expect(input.rect.y + input.rect.height).to be <= panel.rect.y + panel.rect.height
      expect(page.evaluate_script("window.scrollY")).to eq(scroll)
      expect(panel.find_button("Reply").rect.y + panel.find_button("Reply").rect.height).to be <= panel.rect.y + panel.rect.height
      unless resized
        [ "light", "dark" ].each do |theme|
          page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
          page.save_screenshot(Rails.root.join("tmp/composer-preview/growing-reply-#{theme}.png"))
        end
      end
      input.execute_script("this.setSelectionRange(0, 0); this.scrollTop = 0")
      input.send_keys("Edited beginning: ")
      expect(input.evaluate_script("this.scrollTop")).to eq(0)
    end
  end

  it "shows the newly posted reply and returns the empty draft to its compact height" do
    comment.update!(body_markdown: ("Earlier discussion.\n\n" * 30))
    page.refresh
    find("#plan-general-comments button").click
    panel = find(".comment-window:popover-open")
    input = panel.find("textarea")
    input.fill_in with: (1..12).map { |n| "New reply line #{n}" }.join("\n")
    input.send_keys(:enter)
    expect(panel).to have_field("Your reply", with: "", enable_aria_label: true)
    expect(input.rect.height).to be <= 90
    comments = panel.find(".thread-popover__comments")
    expect(comments).to have_text("New reply line 12")
    expect(comments.evaluate_script("this.scrollHeight - this.clientHeight - this.scrollTop")).to be <= 2
  end

  it "keeps a clicked discussion open when the pointer leaves during a reply" do
    fill_in "Your reply", with: "An unfinished thought", enable_aria_label: true
    find("#plan-header").hover
    sleep 0.4 # Beyond the former hover-close delay.
    expect(page).to have_css(".thread-popover:popover-open")
    expect(page).to have_field("Your reply", with: "An unfinished thought", enable_aria_label: true)
  end

  it "moves the entire window without leaving a placeholder, then resizes the draft" do
    find("textarea[aria-label='Your reply']").fill_in with: "A longer reply with a draft to preserve."
    scroll = page.evaluate_script("window.scrollY")
    panel = find(".comment-window:popover-open")
    expect(panel.rect.width).to be <= 380
    before = panel.rect
    panel.find("[aria-label='Move comment window']").send_keys(:left)
    expect(panel.rect.x).to be < before.x
    expect(page).to have_no_css(".composer__return, .composer__panel--floating")
    expect(page).to have_css(".comment-window:popover-open", count: 1)
    before = panel.rect
    input_height = find("textarea[aria-label='Your reply']").rect.height
    panel.find("[aria-label='Resize comment window']").send_keys(:right, :down, :down)
    expect(panel.rect.width).to be > before.width
    expect(panel.rect.height).to be > before.height
    expect(find("textarea[aria-label='Your reply']").rect.height).to be > input_height
    expect(page.evaluate_script("window.scrollY")).to eq(scroll)
    expect(page).to have_field("Your reply", enable_aria_label: true, with: "A longer reply with a draft to preserve.")
  end

  it "starts new comments compact and resizes the whole form without obscuring the old location" do
    page.driver.browser.action.send_keys(:escape).perform
    page.execute_script <<~JS
      const p = document.querySelector('[data-coplan--text-selection-target="content"] p');
      const range = document.createRange(); range.selectNodeContents(p);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      p.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
    JS
    page.driver.browser.action.send_keys('c').perform
    panel = find("#new-comment-form", visible: true)
    expect(panel.rect.width).to eq(360)
    expect(panel.rect.height).to be < 280
    grip = panel.find("[aria-label='Resize comment window']").rect
    send = panel.find("button[type='submit']").rect
    expect(grip.y).to be >= send.y + send.height
    panel.find("textarea").fill_in with: "Keep the passage visible as I write."
    before = panel.rect
    panel.find("[aria-label='Move comment window']").send_keys(:right, :right)
    expect(panel.rect.x).to be > before.x
    expect(page).to have_css(".comment-window:popover-open", count: 1)
    height = panel.find("textarea").rect.height
    panel.find("[aria-label='Resize comment window']").send_keys(:down, :down, :right)
    expect(panel.find("textarea").rect.height).to be > height
    expect(panel.find("textarea").value).to eq("Keep the passage visible as I write.")
  end

  it "keeps the header, reply controls and corner grip inside a shrunken discussion" do
    comment.update!(body_markdown: ("A longer discussion still needs room for a reply.\n\n" * 12))
    page.refresh
    find("#plan-general-comments button").click
    panel = find(".comment-window:popover-open")
    panel.find("textarea").fill_in with: "A draft that survives resizing"
    grip = panel.find("[aria-label='Resize comment window']")
    grip.send_keys(*Array.new(30, :up), *Array.new(4, :left))
    geometry = panel.evaluate_script(<<~JS)
      (() => {
        const box = this.getBoundingClientRect();
        const bar = this.querySelector('.comment-window__bar').getBoundingClientRect();
        const send = this.querySelector('.composer__submit').getBoundingClientRect();
        const grip = this.querySelector('.comment-window__resize').getBoundingClientRect();
        return { topInset: bar.top - box.top, bottomInset: box.bottom - send.bottom,
          gripGap: grip.top - send.bottom, gripBottom: box.bottom - grip.bottom,
          scroll: this.scrollHeight - this.clientHeight };
      })()
    JS
    expect(geometry["topInset"]).to be >= 5
    expect(geometry["bottomInset"]).to be >= 26
    expect(geometry["gripGap"]).to be >= 0
    expect(geometry["gripBottom"]).to be_between(2, 4)
    expect(geometry["scroll"]).to be <= 1
    expect(panel.find("textarea").value).to eq("A draft that survives resizing")
    [ "light", "dark" ].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      page.save_screenshot(Rails.root.join("tmp/composer-preview/resized-discussion-#{theme}.png"))
    end
  end

  it "keeps the top-left corner stationary when resizing against the viewport edge" do
    panel = find(".comment-window:popover-open")
    before = panel.rect
    panel.find("[aria-label='Resize comment window']").send_keys(*Array.new(45, :right), *Array.new(45, :down))
    expect(panel.rect.x).to be_within(1).of(before.x)
    expect(panel.rect.y).to be_within(1).of(before.y)
    expect(panel.rect.width).to be > before.width
  end

  it "keeps the corner grip clear of the send button and unboxed" do
    geometry = page.evaluate_script(<<~JS)
      (() => {
        const panel = document.querySelector('.comment-window:popover-open');
        const grip = panel.querySelector('.comment-window__resize');
        const send = panel.querySelector('.composer__submit');
        return { gripTop: grip.getBoundingClientRect().top, sendBottom: send.getBoundingClientRect().bottom,
          border: getComputedStyle(grip).borderTopWidth, background: getComputedStyle(grip).backgroundColor };
      })()
    JS
    expect(geometry["gripTop"]).to be >= geometry["sendBottom"]
    expect(geometry["border"]).to eq("0px")
    expect(geometry["background"]).to eq("rgba(0, 0, 0, 0)")
  end

  it "dismisses a new comment on outside click and restores its draft for the same passage" do
    page.driver.browser.action.send_keys(:escape).perform
    select_passage = <<~JS
      const p = document.querySelector('[data-coplan--text-selection-target="content"] p');
      const range = document.createRange(); range.selectNodeContents(p);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      p.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
    JS
    page.execute_script(select_passage)
    page.driver.browser.action.send_keys('c').perform
    find("#new-comment-form textarea").fill_in with: "Keep this unfinished thought"
    find("#new-comment-form [aria-label='Move comment window']").send_keys(:right)
    find("h1", text: plan.title).click
    expect(page).to have_no_css("#new-comment-form", visible: true)
    page.execute_script(select_passage)
    page.driver.browser.action.send_keys('c').perform
    expect(page).to have_field("New comment", enable_aria_label: true, with: "Keep this unfinished thought")
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_no_css("#new-comment-form", visible: true)
  end

  it "shares the selected microphone with both dictation controls and captures that input" do
    page.execute_script <<~JS
      window.micConstraints = null;
      navigator.mediaDevices.enumerateDevices = async () => [
        { kind: 'audioinput', deviceId: 'usb-mic', label: 'USB microphone' },
        { kind: 'audioinput', deviceId: 'built-in', label: 'Built-in microphone' }
      ];
      navigator.mediaDevices.getUserMedia = async constraints => {
        window.micConstraints = constraints;
        throw new DOMException('Unplugged', 'OverconstrainedError');
      };
    JS
    within(".thread-popover__reply") { find("[aria-label='Microphone settings']").click }
    find("select[aria-label='Audio input']").select("USB microphone")
    find("textarea[aria-label='Your reply']").click
    page.execute_script <<~JS
      const el = document.querySelector('.thread-popover__reply [data-controller="coplan--dictation"]');
      window.Stimulus.getControllerForElementAndIdentifier(el, 'coplan--dictation').mode = 'record';
    JS
    within(".thread-popover__reply") { click_button "Dictate" }
    expect(page).to have_content("The selected microphone is unavailable")
    expect(page.evaluate_script("window.micConstraints.audio.deviceId.exact")).to eq("usb-mic")
    expect(page).to have_button("Reply", disabled: false)
    page.driver.browser.action.send_keys(:escape).perform
    within(".voice-control") { find("[aria-label='Microphone settings']").click }
    expect(page).to have_select("Audio input", selected: "USB microphone", enable_aria_label: true)
  ensure
    page.execute_script("localStorage.removeItem('coplan:microphone')")
  end

  it "passes the selected microphone track to browser speech recognition and releases it" do
    page.execute_script <<~JS
      localStorage.setItem('coplan:microphone', 'usb-mic');
      window.micStopped = false;
      window.selectedTrack = { kind: 'audio', readyState: 'live', stop() { window.micStopped = true; } };
      navigator.mediaDevices.getUserMedia = async constraints => {
        window.micConstraints = constraints;
        return { getAudioTracks: () => [window.selectedTrack], getTracks: () => [window.selectedTrack] };
      };
      window.SpeechRecognition = class {
        start(track) { window.recognitionTrack = track; }
        stop() {
          const result = [{ transcript: 'From my USB microphone.' }]; result.isFinal = true;
          this.onresult({ results: [result] }); this.onend();
        }
        abort() {}
      };
    JS
    within(".thread-popover__reply") { click_button "Dictate" }
    expect(page).to have_button("Stop")
    expect(page.evaluate_script("window.micConstraints.audio.deviceId.exact")).to eq("usb-mic")
    expect(page.evaluate_script("window.recognitionTrack === window.selectedTrack")).to be(true)
    within(".thread-popover__reply") { click_button "Stop" }
    expect(page).to have_field("Your reply", enable_aria_label: true, with: "From my USB microphone.")
    expect(page.evaluate_script("window.micStopped")).to be(true)
    expect(thread_record.comments.count).to eq(1)
  ensure
    page.execute_script("localStorage.removeItem('coplan:microphone')")
  end

  it "explains speech-service failures without posting or replacing the error with no-speech" do
    page.execute_script <<~JS
      const el = document.querySelector('.thread-popover__reply [data-controller="coplan--dictation"]');
      const controller = window.Stimulus.getControllerForElementAndIdentifier(el, 'coplan--dictation');
      window.SpeechRecognition = class {
        start() { this.onerror({ error: 'network' }); this.onend(); }
        stop() {}
        abort() {}
      };
    JS
    within(".thread-popover__reply") { click_button "Dictate" }
    expect(page).to have_content("The browser's speech service couldn't connect")
    expect(page).to have_button("Reply", disabled: false)
    expect(page).to have_button("Dictate")
    expect(thread_record.comments.count).to eq(1)
  end

  it "edits and saves your comment in place" do
    within(".thread-popover", visible: true) { click_button "Edit" }
    find("textarea[aria-label='Edit comment']").fill_in with: "Revised with **more detail**"
    click_button "Save changes"
    expect(page).to have_css(".comment__body strong", text: "more detail")
    expect(comment.reload.body_markdown).to eq("Revised with **more detail**")
    expect(page).to have_no_field("Edit comment", enable_aria_label: true, visible: true)
  end

  it "cancels an edit without changing the saved comment" do
    within(".thread-popover", visible: true) { click_button "Edit" }
    find("textarea[aria-label='Edit comment']").fill_in with: "Unsent changes"
    click_button "Cancel"
    expect(page).to have_content("A thought worth refining")
    expect(comment.reload.body_markdown).to eq("A thought worth refining")
  end

  it "keeps an invalid edit visible so it can be corrected" do
    within(".thread-popover", visible: true) { click_button "Edit" }
    find("textarea[aria-label='Edit comment']").fill_in with: "   "
    click_button "Save changes"
    expect(page).to have_content("can't be blank")
    expect(page).to have_field("Edit comment", enable_aria_label: true, with: "   ")
    find("textarea[aria-label='Edit comment']").fill_in with: "Corrected draft"
    click_button "Save changes"
    expect(page).to have_css(".comment__body", text: "Corrected draft")
  end

  it "keeps a moved window and its draft within a narrow viewport" do
    find("[aria-label='Move comment window']").send_keys(:left)
    page.current_window.resize_to(390, 700)
    bounds = find(".comment-window:popover-open").rect
    expect(bounds.x).to be >= 0
    expect(bounds.x + bounds.width).to be <= page.evaluate_script("window.innerWidth")
    expect(bounds.height).to be <= page.evaluate_script("window.innerHeight")
    find("textarea[aria-label='Your reply']").fill_in with: "Mobile draft"
    expect(page).to have_field("Your reply", enable_aria_label: true, with: "Mobile draft")
  ensure
    page.current_window.resize_to(1400, 900)
  end

  it "keeps mention suggestions interactive inside the comment window" do
    colleague = create(:coplan_user, username: "glass_reviewer", name: "Glass Reviewer")
    find("textarea[aria-label='Your reply']").fill_in with: "@glass"
    expect(page).to have_css(".mention-picker__item", text: "Glass Reviewer")
    find(".mention-picker__item", text: "Glass Reviewer").click
    expect(page).to have_field("Your reply", enable_aria_label: true, with: "@#{colleague.username} ")
  end

  it "keeps the draft editable when microphone permission is denied" do
    page.execute_script <<~JS
      navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException('Denied', 'NotAllowedError'));
      const element = document.querySelector('.thread-popover__reply [data-controller="coplan--dictation"]');
      window.Stimulus.getControllerForElementAndIdentifier(element, 'coplan--dictation').mode = 'record';
    JS
    find("textarea[aria-label='Your reply']").fill_in with: "Keep this typed draft"
    within(".thread-popover__reply") { click_button "Dictate" }
    expect(page).to have_content("Mic blocked")
    expect(page).to have_button("Reply", disabled: false)
    expect(page).to have_field("Your reply", enable_aria_label: true, with: "Keep this typed draft")
  end

  it "inserts dictated words into the draft without posting them" do
    page.execute_script <<~JS
      window.SpeechRecognition = class {
        start() {}
        stop() {
          const result = [{ transcript: "Some spoken feedback." }];
          result.isFinal = true;
          this.onresult({ results: [result] });
          this.onend();
        }
        abort() {}
      };
      const element = document.querySelector('.thread-popover__reply [data-controller="coplan--dictation"]');
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, 'coplan--dictation');
      controller.disconnect(); controller.connect();
    JS
    find("textarea[aria-label='Your reply']").fill_in with: "Typed first."
    within(".thread-popover__reply") { click_button "Dictate" }
    expect(page).to have_button("Stop")
    expect(page).to have_button("Reply", disabled: true)
    within(".thread-popover__reply") { click_button "Stop" }
    expect(page).to have_field("Your reply", enable_aria_label: true, with: "Typed first. Some spoken feedback.")
    expect(thread_record.comments.count).to eq(1)
    expect(page).to have_button("Reply", disabled: false)
  end
end
