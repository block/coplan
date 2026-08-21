require "rails_helper"

# SLIDE_SPEC.md's conformance blocks are the classifier's acceptance suite
# (CommonMark's trick: the spec's examples ARE the tests, so spec text and
# implementation cannot drift apart). Each ```conformance fence holds a
# slide's markdown, a lone "." line, then expected `key: value` pairs.
RSpec.describe "SLIDE_SPEC.md conformance", type: :service do
  SPEC_PATH = File.expand_path("../../../docs/SLIDE_SPEC.md", __dir__)

  Example = Struct.new(:label, :line, :markdown, :expected, keyword_init: true)

  def self.conformance_examples
    examples = []
    heading = "top"
    fence = nil

    File.readlines(SPEC_PATH).each_with_index do |line, index|
      if fence.nil?
        heading = Regexp.last_match(1).strip if line =~ /\A#+\s+`?([^`\n]+)/
        fence = { close: "#{Regexp.last_match(1)}\n", start: index + 1, lines: [] } if line =~ /\A(`{3,})conformance\s*\z/
      elsif line == fence[:close]
        examples << build_example(heading, fence, examples)
        fence = nil
      else
        fence[:lines] << line
      end
    end

    raise "unclosed conformance fence at SLIDE_SPEC.md:#{fence[:start]}" if fence
    examples
  end

  def self.build_example(heading, fence, examples)
    separator = fence[:lines].index(".\n") || raise("conformance block at SLIDE_SPEC.md:#{fence[:start]} has no '.' separator")
    expected = fence[:lines].drop(separator + 1).to_h do |line|
      key, value = line.strip.split(":", 2)
      raise "bad expectation #{line.inspect} at SLIDE_SPEC.md:#{fence[:start]}" if value.nil?

      [ key, value.strip ]
    end

    ordinal = examples.count { |example| example.label.start_with?(heading) } + 1
    Example.new(label: "#{heading} ##{ordinal}", line: fence[:start],
                markdown: fence[:lines].take(separator).join, expected: expected)
  end

  examples = conformance_examples

  it "extracts a healthy number of examples" do
    expect(examples.size).to be >= 15
  end

  examples.each do |example|
    it "#{example.label} (SLIDE_SPEC.md:#{example.line})" do
      classification = CoPlan::Slideshows::Classify.call(example.markdown)

      expect(classification.pattern.to_s).to eq(example.expected.fetch("pattern")),
        "expected pattern #{example.expected["pattern"]}, got #{classification.pattern} (step #{classification.step})"
      if example.expected["step"]
        expect(classification.step).to eq(Integer(example.expected["step"]))
      end
      if example.expected["media"]
        expect(classification.media.to_s).to eq(example.expected["media"])
      end
    end
  end
end
