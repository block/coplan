require "rails_helper"

RSpec.describe CoPlan::Slug do
  [ :call, :handle ].each do |method|
    describe ".#{method}" do
      it "accepts binary-tagged ASCII from host authentication" do
        expect(described_class.public_send(method, "alice.smith".b)).to eq("alice-smith")
      end

      it "preserves UTF-8 bytes in binary-tagged text without modifying the input" do
        text = "Café 東京".b.freeze

        expected = method == :call ? "café-東京" : "cafe"
        expect(described_class.public_send(method, text)).to eq(expected)
        expect(text.encoding).to eq(Encoding::BINARY)
        expect(text.bytes).to eq("Café 東京".bytes)
      end

      it "transcodes text with a declared non-Unicode encoding" do
        text = "Café".encode(Encoding::ISO_8859_1)

        expected = method == :call ? "café" : "cafe"
        expect(described_class.public_send(method, text)).to eq(expected)
      end

      it "treats invalid bytes as separators" do
        [ "alice\xFFsmith".b, "alice\xFFsmith" ].each do |text|
          expect(described_class.public_send(method, text)).to eq("alice-smith")
        end
      end

      it "preserves Unicode normalization for ordinary UTF-8 text" do
        expected = method == :call ? "café" : "cafe"
        expect(described_class.public_send(method, "Cafe\u0301")).to eq(expected)
      end

      it "returns an empty slug for nil" do
        expect(described_class.public_send(method, nil)).to eq("")
      end
    end
  end
end
