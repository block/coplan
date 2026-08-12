require "rails_helper"

RSpec.describe CoPlan::Comments::InterpretDictation do
  let(:excerpt) do
    <<~TEXT
      Pilot usage, first four weeks
      Median latency was 340 milliseconds across the pilot cohort.
      The higher-fidelity sidecar stays behind a flag until it is proven.
    TEXT
  end

  def stub_ai(text:, span: nil)
    allow(CoPlan::Ai).to receive(:call).and_return({ "text" => text, "span" => span }.to_json)
  end

  it "returns the cleaned remark and the span it refers to" do
    stub_ai(
      text: "Put the median latency in seconds in the header.",
      span: "Median latency was 340 milliseconds across the pilot cohort."
    )

    result = described_class.call(
      excerpt: excerpt,
      transcript: "put the medium weight latency I put the like the speed at the units of seconds like on the header"
    )

    expect(result.body).to eq("Put the median latency in seconds in the header.")
    expect(result.anchor_text).to eq("Median latency was 340 milliseconds across the pilot cohort.")
  end

  it "reads JSON the model wrapped in a code fence" do
    allow(CoPlan::Ai).to receive(:call).and_return(<<~RESPONSE)
      ```json
      {"text": "This is too cautious.", "span": null}
      ```
    RESPONSE

    result = described_class.call(excerpt: excerpt, transcript: "this is like too cautious")

    expect(result.body).to eq("This is too cautious.")
    expect(result.anchor_text).to be_nil
  end

  # A "cleanup" that loses or invents half the remark has become a
  # summary, and the person's own words are better than that.
  it "keeps their words when the rewrite changes length drastically" do
    transcript = "the rollout section needs to say which week we ship to everyone and who signs off"
    stub_ai(text: "Fix rollout.")

    expect(described_class.call(excerpt: excerpt, transcript: transcript).body)
      .to eq("The rollout section needs to say which week we ship to everyone and who signs off")
  end

  it "keeps their words when the model pads it out" do
    transcript = "too formal"
    stub_ai(text: "I believe this particular passage reads far too formally for our intended audience.")

    expect(described_class.call(excerpt: excerpt, transcript: transcript).body).to eq("Too formal")
  end

  it "rejects a span that is a paraphrase rather than a quotation" do
    stub_ai(text: "Too cautious.", span: "the sidecar is gated behind a feature flag")

    expect(described_class.call(excerpt: excerpt, transcript: "too cautious").anchor_text).to be_nil
  end

  it "forgives quote marks the model wraps around the span" do
    stub_ai(text: "Too cautious.", span: %(“Median latency was 340 milliseconds across the pilot cohort.”))

    expect(described_class.call(excerpt: excerpt, transcript: "too cautious").anchor_text)
      .to eq("Median latency was 340 milliseconds across the pilot cohort.")
  end

  it "rejects a span long enough to be a block quote rather than a pointer" do
    stub_ai(text: "All of this.", span: excerpt.strip + (" padding to exceed the cap." * 40))

    expect(described_class.call(excerpt: excerpt, transcript: "all of this").anchor_text).to be_nil
  end

  it "falls back to a local tidy-up when the response isn't JSON" do
    allow(CoPlan::Ai).to receive(:call).and_return("Sure! Here's the cleaned up comment.")

    result = described_class.call(excerpt: excerpt, transcript: "this is, like, too formal")

    expect(result.body).to eq("This is too formal")
    expect(result.anchor_text).to be_nil
  end

  it "falls back to a local tidy-up when the AI is unavailable" do
    allow(CoPlan::Ai).to receive(:call).and_raise(CoPlan::Ai::Error, "no API key configured")

    result = described_class.call(excerpt: excerpt, transcript: "um this is you know too formal")

    expect(result.body).to eq("This is too formal")
    expect(result.anchor_text).to be_nil
  end

  # "like" is a real word far more often than it's a tic, so the local
  # pass only drops it where the sentence marks it as filler.
  it "leaves a genuine 'like' alone" do
    allow(CoPlan::Ai).to receive(:call).and_raise(CoPlan::Ai::Error, "no API key configured")

    result = described_class.call(excerpt: excerpt, transcript: "it looks like the sidecar is gated")

    expect(result.body).to eq("It looks like the sidecar is gated")
  end

  it "does not call the AI without a transcript" do
    expect(CoPlan::Ai).not_to receive(:call)

    expect(described_class.call(excerpt: excerpt, transcript: "  ").body).to eq("")
  end
end
