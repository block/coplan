require "rails_helper"

RSpec.describe "Dictations", type: :request do
  let(:alice) { create(:coplan_user, :admin) }

  # An anchor is only worth returning if it resolves against the plan's
  # own markdown, so these specs need a plan that actually says the thing
  # the model quotes back.
  let(:plan) do
    create(:plan, :considering, created_by_user: alice).tap do |p|
      version = create(:plan_version, plan: p, revision: 2, actor_id: alice.id,
        content_markdown: "## Ambition\n\nOur goal is world domination by Q3.\n")
      p.update_columns(current_plan_version_id: version.id, current_revision: 2)
    end
  end

  before { sign_in_as(alice) }

  it "returns the cleaned body and the span" do
    allow(CoPlan::Ai).to receive(:call)
      .and_return({ "text" => "This is too grand.", "span" => "world domination" }.to_json)

    post plan_dictations_path(plan),
      params: { transcript: "this is like um too grand", excerpt: "Our goal is world domination by Q3." },
      as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["body"]).to eq("This is too grand.")
    expect(body["anchor_text"]).to eq("world domination")
  end

  it "returns a locally tidied transcript rather than an error when the AI can't help" do
    allow(CoPlan::Ai).to receive(:call).and_raise(CoPlan::Ai::Error, "not configured")

    post plan_dictations_path(plan),
      params: { transcript: "um too formal", excerpt: "Our goal is world domination by Q3." },
      as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["body"]).to eq("Too formal")
    expect(JSON.parse(response.body)["anchor_text"]).to be_nil
  end

  # Only what was on screen goes to the model — narrower is more accurate,
  # cheaper, and sends less of the document off the box.
  it "sends the visible excerpt, not the whole document" do
    expect(CoPlan::Ai).to receive(:call) do |system_prompt:, user_content:|
      expect(user_content).to include("only this paragraph was visible")
      expect(user_content).not_to include(plan.current_content)
      expect(system_prompt).to include("filler words")
      { "text" => "Tighten this.", "span" => nil }.to_json
    end

    post plan_dictations_path(plan),
      params: { transcript: "tighten this", excerpt: "only this paragraph was visible" },
      as: :json

    expect(JSON.parse(response.body)["body"]).to eq("Tighten this.")
  end

  it "falls back to the plan content when the client sends no excerpt" do
    expect(CoPlan::Ai).to receive(:call) do |user_content:, **|
      expect(user_content).to include(plan.current_content.truncate(50, omission: ""))
      { "text" => "Tighten this.", "span" => nil }.to_json
    end

    post plan_dictations_path(plan), params: { transcript: "tighten this" }, as: :json

    expect(response).to have_http_status(:ok)
  end

  describe "with recorded audio instead of a transcript" do
    def audio_upload(content = "fake audio", type: "audio/webm", extension: ".webm")
      file = Tempfile.new([ "dictation", extension ], binmode: true)
      file.write(content)
      file.rewind
      Rack::Test::UploadedFile.new(file.path, type)
    end

    it "transcribes the recording and interprets what it heard" do
      expect(CoPlan::Ai).to receive(:transcribe) do |file:, context:|
        # OpenAI reads the format off the filename, so the extension has
        # to survive the round trip from the browser's blob.
        expect(File.extname(file.path)).to eq(".webm")
        expect(File.read(file.path)).to eq("fake audio")
        expect(context).to include("world domination")
        "this is like um too grand"
      end
      allow(CoPlan::Ai).to receive(:call)
        .and_return({ "text" => "This is too grand.", "span" => "world domination" }.to_json)

      post plan_dictations_path(plan),
        params: { audio: audio_upload, excerpt: "Our goal is world domination by Q3." }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["transcript"]).to eq("this is like um too grand")
      expect(body["body"]).to eq("This is too grand.")
      expect(body["anchor_text"]).to eq("world domination")
    end

    it "keeps Safari's MP4 recording as an MP4" do
      expect(CoPlan::Ai).to receive(:transcribe) do |file:, **|
        expect(File.extname(file.path)).to eq(".mp4")
        "too grand"
      end
      allow(CoPlan::Ai).to receive(:call)
        .and_return({ "text" => "Too grand.", "span" => nil }.to_json)

      post plan_dictations_path(plan),
        params: { audio: audio_upload(type: "audio/mp4", extension: ".mp4") }

      expect(response).to have_http_status(:ok)
    end

    # There is nothing to fall back to — no words were captured anywhere
    # else — so the client needs to hear that rather than post silence.
    it "reports failure rather than posting an empty comment" do
      allow(CoPlan::Ai).to receive(:transcribe).and_raise(CoPlan::Ai::Error, "unavailable")
      expect(CoPlan::Ai).not_to receive(:call)

      post plan_dictations_path(plan), params: { audio: audio_upload }

      expect(response).to have_http_status(:bad_gateway)
      expect(JSON.parse(response.body)["error"]).to be_present
    end

    it "refuses a recording too large to be a spoken remark" do
      stub_const("CoPlan::DictationsController::MAX_AUDIO_BYTES", 4)
      expect(CoPlan::Ai).not_to receive(:transcribe)

      post plan_dictations_path(plan), params: { audio: audio_upload("far too many bytes") }

      expect(response).to have_http_status(:bad_gateway)
    end

    # Whisper-family models answer silence by repeating their prompt, and
    # we prompt with the text that was on screen. Left alone this posts a
    # sentence lifted off the page as though the person had said it —
    # pinned, plausible, and entirely invented.
    describe "when the transcriber echoes the prompt back" do
      it "reports hearing nothing rather than posting the page back" do
        allow(CoPlan::Ai).to receive(:transcribe).and_return("Our goal is world domination")
        expect(CoPlan::Ai).not_to receive(:call)

        post plan_dictations_path(plan),
          params: { audio: audio_upload, excerpt: "Our goal is world domination by Q3." }

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq("Didn't hear anything")
      end

      it "ignores case and line breaks, which the echo doesn't preserve" do
        allow(CoPlan::Ai).to receive(:transcribe).and_return("our goal is\nWORLD DOMINATION")

        post plan_dictations_path(plan),
          params: { audio: audio_upload, excerpt: "Our goal is world domination by Q3." }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "treats an empty transcript the same way" do
        allow(CoPlan::Ai).to receive(:transcribe).and_return("")

        post plan_dictations_path(plan), params: { audio: audio_upload, excerpt: "Anything." }

        expect(response).to have_http_status(:unprocessable_content)
      end

      # A remark that merely mentions words from the page is the normal
      # case — it's what commenting on a document sounds like.
      it "lets through a remark that quotes only part of the page" do
        allow(CoPlan::Ai).to receive(:transcribe).and_return("is world domination really the goal here")
        allow(CoPlan::Ai).to receive(:call)
          .and_return({ "text" => "Is world domination really the goal?", "span" => nil }.to_json)

        post plan_dictations_path(plan),
          params: { audio: audio_upload, excerpt: "Our goal is world domination by Q3." }

        expect(response).to have_http_status(:ok)
      end
    end

    # A browser that transcribed for itself has already done the work.
    it "prefers a transcript the browser supplies" do
      expect(CoPlan::Ai).not_to receive(:transcribe)
      allow(CoPlan::Ai).to receive(:call)
        .and_return({ "text" => "Too grand.", "span" => nil }.to_json)

      post plan_dictations_path(plan),
        params: { transcript: "too grand", audio: audio_upload }

      expect(response).to have_http_status(:ok)
    end
  end

  # Plans are readable by link (PlanPolicy#show? is true, same as
  # commenting), so the boundary that matters here is being signed in at
  # all — an anonymous visitor must not be able to spend AI calls.
  it "does not run for a signed-out visitor" do
    reset! # drops the signed-in session established above

    expect(CoPlan::Ai).not_to receive(:call)
    post plan_dictations_path(plan), params: { transcript: "hi" }, as: :json

    expect(response).not_to have_http_status(:ok)
  end
end
