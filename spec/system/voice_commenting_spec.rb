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
  def stub_speech_recognition(transcript)
    page.driver.browser.execute_cdp(
      "Page.addScriptToEvaluateOnNewDocument",
      source: <<~JS
        window.SpeechRecognition = class {
          start() {
            setTimeout(() => {
              // Shaped like a real SpeechRecognitionResultList: an
              // iterable of results, each indexable by alternative, and
              // isFinal is what tells the controller it's done.
              const result = [{ transcript: #{transcript.to_json} }]
              result.isFinal = true
              this.onresult({ results: [result] })
              this.onend()
            }, 10)
          }
          stop() {}
          abort() {}
        }
      JS
    )
  end

  before { sign_in(author) }

  it "pins a dictated comment to the passage the AI identifies" do
    allow(CoPlan::Ai).to receive(:call)
      .and_return("The higher-fidelity sidecar stays behind a flag until it is proven.")

    stub_speech_recognition("this bit is way too cautious")
    visit plan_path(plan)

    find(".voice-btn").click

    expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)

    thread = CoPlan::CommentThread.where(plan_id: plan.id).last
    expect(thread.anchor_text).to eq("The higher-fidelity sidecar stays behind a flag until it is proven.")
    expect(thread.comments.first.body_markdown).to eq("🎙️ this bit is way too cautious")
    # The anchor has to resolve against the document, or there's no pin.
    # anchor_start is what actually produces the highlight — a thread with
    # anchor_text that never resolved is a pin pointing at nothing.
    expect(thread).to be_anchored
    expect(thread.anchor_start).to be_present
    expect(plan.current_content[thread.anchor_start...thread.anchor_end])
      .to eq("The higher-fidelity sidecar stays behind a flag until it is proven.")
  end

  # The AI is an enhancement. When it can't answer, the comment still has
  # to land somewhere visible rather than becoming an invisible thread.
  it "falls back to the section heading when the AI can't identify a span" do
    allow(CoPlan::Ai).to receive(:call).and_raise(CoPlan::Ai::Error, "not configured")

    stub_speech_recognition("something about this section")
    visit plan_path(plan)

    find(".voice-btn").click

    expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)

    thread = CoPlan::CommentThread.where(plan_id: plan.id).last
    expect(thread.anchor_text).to be_present
    expect(thread).to be_anchored
    expect(thread.anchor_start).to be_present
  end

  # Nothing in the flow may claim an agent is coming: with none attached,
  # a dictated comment is just a comment.
  it "never promises an agent" do
    allow(CoPlan::Ai).to receive(:call).and_return("NONE")

    stub_speech_recognition("no agent is attached here")
    visit plan_path(plan)

    find(".voice-btn").click

    expect(page).to have_css(".voice-status", text: /Comment added/, wait: 10)
    expect(page).to have_no_css(".voice-status", text: /waiting for the agent/i)
    expect(page).to have_no_css(".agent-pill")
  end
end
