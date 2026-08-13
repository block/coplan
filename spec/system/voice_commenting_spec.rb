require "rails_helper"

# The voice control is the one feature whose whole value is what happens
# in the browser: transcribe, work out which passage was meant, and pin a
# comment there. Headless Chrome has no microphone, so SpeechRecognition
# is replaced with a fake that emits a fixed transcript on demand — every
# other step is the real thing.
RSpec.describe "Voice commenting", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }

  let(:plan_content) do
    <<~MARKDOWN
      # Launch Plan

      ## Goals

      We will ship the voice tier to everyone in the first week.

      ## Rollout

      The higher-fidelity sidecar stays behind a flag until it is proven.
    MARKDOWN
  end

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Launch Plan", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: plan_content, actor_type: "human", actor_id: author.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  # Installed before any page script runs, so the Stimulus controller sees
  # a browser that can transcribe and renders the mic button.
  #
  # Two real behaviours to model, and which one is in play matters:
  #   - tap the button: continuous = false, so the browser decides speech
  #     has ended and fires the result on its own.
  #   - hold to talk: the result arrives because stop() was called on
  #     release, and abort() throws away whatever was captured.
  # A fake that always emits on start() would make "cancel" look like it
  # posted, because the post would have happened before the cancel.
  def stub_speech_recognition(transcript, emit_on_stop: false)
    page.driver.browser.execute_cdp(
      "Page.addScriptToEvaluateOnNewDocument",
      source: <<~JS
        window.SpeechRecognition = class {
          _emit() {
            if (this._done) return
            this._done = true
            // Shaped like a real SpeechRecognitionResultList: an iterable
            // of results, each indexable by alternative, and isFinal is
            // what tells the controller the transcript is settled.
            const result = [{ transcript: #{transcript.to_json} }]
            result.isFinal = true
            this.onresult({ results: [result] })
            this.onend()
          }
          start() {
            this._done = false
            if (!#{emit_on_stop}) setTimeout(() => this._emit(), 10)
          }
          stop() { this._emit() }
          abort() { this._done = true }
        }
      JS
    )
  end

  # Recording + server transcription is the better path and the default
  # wherever a provider is configured, so the browser's own recognition
  # has to be asked for explicitly. Its own tests are further down.
  before do
    allow(CoPlan::Ai).to receive(:available?).and_return(false)
    sign_in(author)
  end

  it "cleans up the remark and pins it to the passage the AI identifies" do
    allow(CoPlan::Ai).to receive(:call).and_return({
      "text" => "This bit is too cautious.",
      "span" => "The higher-fidelity sidecar stays behind a flag until it is proven."
    }.to_json)

    stub_speech_recognition("this bit is like way too like cautious")
    visit plan_path(plan)

    find(".voice-btn").click

    expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)

    thread = CoPlan::CommentThread.where(plan_id: plan.id).last
    expect(thread.anchor_text).to eq("The higher-fidelity sidecar stays behind a flag until it is proven.")
    expect(thread.comments.first.body_markdown).to eq("🎙️ This bit is too cautious.")
    # The anchor has to resolve against the document, or there's no pin.
    # anchor_start is what actually produces the highlight — a thread with
    # anchor_text that never resolved is a pin pointing at nothing.
    expect(thread).to be_anchored
    expect(thread.anchor_start).to be_present
    expect(plan.current_content[thread.anchor_start...thread.anchor_end])
      .to eq("The higher-fidelity sidecar stays behind a flag until it is proven.")
  end

  # The AI is an enhancement. When it can't answer, the comment still has
  # to land somewhere visible rather than becoming an invisible thread,
  # and the client's own tidy-up still takes the worst tics out.
  it "falls back to the heading and a local cleanup when the AI is down" do
    allow(CoPlan::Ai).to receive(:call).and_raise(CoPlan::Ai::Error, "not configured")

    stub_speech_recognition("um this section is, you know, like like too vague")
    visit plan_path(plan)

    find(".voice-btn").click

    expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)

    thread = CoPlan::CommentThread.where(plan_id: plan.id).last
    expect(thread.anchor_text).to be_present
    expect(thread).to be_anchored
    expect(thread.anchor_start).to be_present

    body = thread.comments.first.body_markdown
    expect(body).not_to match(/\bum\b/i)
    expect(body).not_to match(/you know/i)
    expect(body).not_to match(/like like/i)
    expect(body).to include("too vague")
  end

  describe "hold Shift to talk" do
    HOLD = 0.7 # comfortably past the controller's 350ms hold delay

    before do
      allow(CoPlan::Ai).to receive(:call)
        .and_return({ "text" => "Held to talk.", "span" => nil }.to_json)
    end

    # Shift left held would make the next test type its email in capitals
    # and land back on the sign-in page, so releasing is unconditional —
    # both here and in the ensure below.
    after { page.driver.browser.action.release_actions }

    # The wait has to happen between two separate `perform` calls. A
    # `pause` inside one chain blocks the renderer's task queue for its
    # duration, so the controller's hold timer doesn't fire until after
    # the release — the hold looks like a tap and nothing is ever
    # recorded. Only the test harness behaves that way; a real keyboard
    # doesn't stop the clock.
    def hold_shift(duration = HOLD)
      page.driver.browser.action.key_down(:shift).perform
      sleep duration
      yield if block_given?
    ensure
      page.driver.browser.action.key_up(:shift).perform
    end

    it "records while Shift is held and posts on release" do
      stub_speech_recognition("held to talk", emit_on_stop: true)
      visit plan_path(plan)

      hold_shift
      expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)

      thread = CoPlan::CommentThread.where(plan_id: plan.id).sole
      expect(thread.comments.first.body_markdown).to eq("🎙️ Held to talk.")
    end

    # Shift is held constantly while typing capitals; a tap must not open
    # the mic, or the feature is unusable on any page with a text field.
    it "ignores a quick tap of Shift" do
      stub_speech_recognition("should never be sent", emit_on_stop: true)
      visit plan_path(plan)

      page.driver.browser.action.key_down(:shift).key_up(:shift).perform

      expect(page).to have_no_css(".voice-btn--listening", wait: 2)
      expect(CoPlan::CommentThread.where(plan_id: plan.id).count).to eq(0)
    end

    # Shift+key is a shortcut or a capital letter, not speech — and
    # whatever was captured must be discarded rather than posted.
    it "cancels without posting when another key is pressed" do
      stub_speech_recognition("should never be sent", emit_on_stop: true)
      visit plan_path(plan)

      hold_shift do
        expect(page).to have_css(".voice-btn--listening")
        page.driver.browser.action.send_keys("a").perform
      end

      expect(page).to have_no_css(".voice-btn--listening", wait: 5)
      expect(CoPlan::CommentThread.where(plan_id: plan.id).count).to eq(0)
    end
  end

  # The path that works in Safari and Firefox, and the better one in
  # Chrome too: capture audio, let the server transcribe it. Nothing here
  # touches SpeechRecognition, which those browsers don't usefully have.
  describe "recording for the server to transcribe" do
    before { allow(CoPlan::Ai).to receive(:available?).and_return(true) }

    # `peak` is how far the loudest sample sits from silence, on the
    # 0–128 scale the controller meters. 30 is ordinary speech; 0 is a
    # microphone that captured nothing.
    #
    # `context_state` models the AudioContext lifecycle. "suspended" is
    # what push-to-talk actually gets — Chrome doesn't treat a bare Shift
    # keydown as a user gesture, so the meter never produces a sample and
    # its all-zero reading must not be mistaken for a silent room.
    def stub_recorder(peak: 30, context_state: "running")
      page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
        delete window.SpeechRecognition
        delete window.webkitSpeechRecognition
        Object.defineProperty(navigator, "mediaDevices", {
          configurable: true,
          value: { getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] }) }
        })
        window.AudioContext = class {
          constructor() { this.state = #{context_state.to_json} }
          resume() { return Promise.resolve() } // stays suspended, as without a gesture
          createAnalyser() {
            const state = () => this.state
            return {
              fftSize: 512,
              getByteTimeDomainData(samples) {
                samples.fill(state() === "running" ? 128 + #{peak} : 128)
              }
            }
          }
          createMediaStreamSource() { return { connect() {} } }
          close() {}
        }
        window.MediaRecorder = class {
          static isTypeSupported() { return true }
          constructor(stream, options) {
            this.mimeType = (options || {}).mimeType || "audio/webm"
            this.state = "inactive"
          }
          start() { this.state = "recording" }
          stop() {
            this.state = "inactive"
            this.ondataavailable({ data: new Blob(["fake audio"], { type: this.mimeType }) })
            if (this.onstop) this.onstop()
          }
        }
      JS
    end

    it "sends the recording and posts what comes back" do
      allow(CoPlan::Ai).to receive(:transcribe).and_return("this bit is like way too like cautious")
      allow(CoPlan::Ai).to receive(:call).and_return({
        "text" => "This bit is too cautious.",
        "span" => "The higher-fidelity sidecar stays behind a flag until it is proven."
      }.to_json)

      stub_recorder
      visit plan_path(plan)

      find(".voice-btn").click
      expect(page).to have_css(".voice-btn--listening")
      find(".voice-btn").click

      expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)

      thread = CoPlan::CommentThread.where(plan_id: plan.id).sole
      expect(thread.comments.first.body_markdown).to eq("🎙️ This bit is too cautious.")
      expect(thread).to be_anchored
    end

    # What was on screen is passed as a transcription hint, which is what
    # makes domain words come back as words rather than phonetic guesses.
    it "gives the transcriber the text that was on screen" do
      expect(CoPlan::Ai).to receive(:transcribe) do |file:, context:|
        expect(File.read(file.path)).to eq("fake audio")
        expect(context).to include("higher-fidelity sidecar")
        "too cautious"
      end
      allow(CoPlan::Ai).to receive(:call)
        .and_return({ "text" => "Too cautious.", "span" => nil }.to_json)

      stub_recorder
      visit plan_path(plan)

      find(".voice-btn").click
      find(".voice-btn").click

      expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)
    end

    # The gesture that kept "not hearing" people: hold-to-talk used to
    # open the microphone only after the 350ms hold was confirmed, so the
    # first word or two of every short remark predated the recording. The
    # ear now opens at the keydown itself, and confirming the hold adopts
    # a capture already in progress.
    it "captures from the press when talking with Shift held" do
      allow(CoPlan::Ai).to receive(:transcribe).and_return("oh I meant both of them")
      allow(CoPlan::Ai).to receive(:call)
        .and_return({ "text" => "Oh — I meant both of them.", "span" => nil }.to_json)

      stub_recorder
      visit plan_path(plan)

      page.driver.browser.action.key_down(:shift).perform
      sleep 0.7
      expect(page).to have_css(".voice-btn--listening")
      page.driver.browser.action.key_up(:shift).perform

      expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)
      thread = CoPlan::CommentThread.where(plan_id: plan.id).sole
      expect(thread.comments.first.body_markdown).to eq("🎙️ Oh — I meant both of them.")
    ensure
      page.driver.browser.action.release_actions
    end

    # The failure that shipped: a recording with nothing in it still went
    # to the transcriber, which answered silence by repeating the context
    # we sent — so a heading off the page arrived as a comment, pinned to
    # itself, that nobody had said. The microphone knows it heard nothing
    # long before the server can, so it never gets sent.
    it "doesn't send a recording it heard nothing in" do
      expect(CoPlan::Ai).not_to receive(:transcribe)

      stub_recorder(peak: 0)
      visit plan_path(plan)

      find(".voice-btn").click
      find(".voice-btn").click

      expect(page).to have_css(".voice-status--error", text: /didn't hear anything/i, wait: 5)
      expect(CoPlan::CommentThread.where(plan_id: plan.id).count).to eq(0)
    end

    # The first regression this guard caused: a suspended AudioContext
    # meters exactly like a silent room, and the silence check threw away
    # recordings people were audibly speaking into. A meter that never
    # ran gets no vote — the take is sent, and the server's echo check
    # remains the defence against actual silence.
    it "sends the recording when the meter never ran, rather than calling speech silence" do
      allow(CoPlan::Ai).to receive(:transcribe).and_return("it should be main and master")
      allow(CoPlan::Ai).to receive(:call)
        .and_return({ "text" => "It should be main and master.", "span" => nil }.to_json)

      stub_recorder(peak: 0, context_state: "suspended")
      visit plan_path(plan)

      find(".voice-btn").click
      find(".voice-btn").click

      expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)
      thread = CoPlan::CommentThread.where(plan_id: plan.id).sole
      expect(thread.comments.first.body_markdown).to eq("🎙️ It should be main and master.")
    end

    # Audio has no fallback: unlike a browser transcript there are no
    # words to post if transcription fails, so say so rather than posting
    # an empty comment.
    it "says so when the recording can't be made out" do
      allow(CoPlan::Ai).to receive(:transcribe).and_raise(CoPlan::Ai::Error, "unavailable")

      stub_recorder
      visit plan_path(plan)

      find(".voice-btn").click
      find(".voice-btn").click

      # The server's own wording, not a generic one: "couldn't reach the
      # transcriber" and "heard nothing" call for different next moves.
      expect(page).to have_css(".voice-status--error", text: /Couldn't make out the recording/, wait: 10)
      expect(CoPlan::CommentThread.where(plan_id: plan.id).count).to eq(0)
    end
  end

  # Nothing in the flow may claim an agent is coming: with none attached,
  # a dictated comment is just a comment.
  it "never promises an agent" do
    allow(CoPlan::Ai).to receive(:call)
      .and_return({ "text" => "No agent is attached here.", "span" => nil }.to_json)

    stub_speech_recognition("no agent is attached here")
    visit plan_path(plan)

    find(".voice-btn").click

    expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)
    expect(page).to have_no_css(".voice-status", text: /waiting for the agent/i)
    expect(page).to have_no_css(".agent-pill")
  end
end
