require "rails_helper"

RSpec.describe CoPlan::Comments::SuggestAnchor do
  let(:excerpt) do
    <<~TEXT
      Rollout
      We will ship the voice tier to everyone in the first week.
      The higher-fidelity sidecar stays behind a flag until it is proven.
    TEXT
  end

  def stub_ai(response)
    allow(CoPlan::Ai).to receive(:call).and_return(response)
  end

  it "returns the span the model picked when it appears verbatim" do
    stub_ai("The higher-fidelity sidecar stays behind a flag until it is proven.")

    expect(described_class.call(excerpt: excerpt, transcript: "this bit is too cautious"))
      .to eq("The higher-fidelity sidecar stays behind a flag until it is proven.")
  end

  it "forgives quote marks the model adds around the span" do
    stub_ai(%(“We will ship the voice tier to everyone in the first week.”))

    expect(described_class.call(excerpt: excerpt, transcript: "too aggressive"))
      .to eq("We will ship the voice tier to everyone in the first week.")
  end

  # A paraphrase can't be highlighted, so the caller has to fall back
  # rather than anchor to text that isn't in the document.
  it "rejects a paraphrase" do
    stub_ai("the sidecar is gated behind a feature flag")

    expect(described_class.call(excerpt: excerpt, transcript: "too cautious")).to be_nil
  end

  it "returns nil when the model declines" do
    stub_ai("NONE")

    expect(described_class.call(excerpt: excerpt, transcript: "the whole thing reads oddly")).to be_nil
  end

  it "rejects a span long enough to be a block quote rather than a pointer" do
    stub_ai(excerpt.strip + (" padding to exceed the cap." * 40))

    expect(described_class.call(excerpt: excerpt, transcript: "all of this")).to be_nil
  end

  it "returns nil rather than raising when the AI is unavailable" do
    allow(CoPlan::Ai).to receive(:call).and_raise(CoPlan::Ai::Error, "no API key configured")

    expect(described_class.call(excerpt: excerpt, transcript: "too formal")).to be_nil
  end

  it "does not call the AI without something to work with" do
    expect(CoPlan::Ai).not_to receive(:call)

    expect(described_class.call(excerpt: "", transcript: "too formal")).to be_nil
    expect(described_class.call(excerpt: excerpt, transcript: "  ")).to be_nil
  end
end
