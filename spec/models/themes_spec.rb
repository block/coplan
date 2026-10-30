require "rails_helper"

RSpec.describe CoPlan::Themes do
  around do |example|
    original = CoPlan.configuration.default_theme
    example.run
  ensure
    CoPlan.configuration.default_theme = original
  end

  it "ships Classic as the default theme" do
    expect(described_class.keys).to include("classic")
    expect(CoPlan.configuration.default_theme).to eq("classic")
    expect(described_class.default).to eq(described_class.find("classic"))
  end

  it "uses the host's configured default, given as a string or a symbol" do
    paper = described_class::Theme.new(key: "paper", name: "Paper", description: "A test theme.")
    stub_const("CoPlan::Themes::ALL", [ *described_class::ALL, paper ])

    CoPlan.configuration.default_theme = "paper"
    expect(described_class.default).to eq(paper)
    CoPlan.configuration.default_theme = :paper
    expect(described_class.default).to eq(paper)
  end

  it "ships Neutral as an opt-in theme" do
    expect(described_class.find("neutral")).to have_attributes(name: "Neutral")
    CoPlan.configuration.default_theme = "neutral"
    expect(described_class.default.key).to eq("neutral")
  end

  it "falls back to Classic for an unknown theme" do
    CoPlan.configuration.default_theme = "hotdog-stand"
    expect(described_class.default.key).to eq("classic")
    expect(described_class.find("hotdog-stand")).to be_nil
  end

  describe ".check_default!" do
    let(:logger) { instance_double(Logger, warn: nil) }

    it "accepts a known theme" do
      expect { described_class.check_default!(env: "production".inquiry, logger: logger) }.not_to raise_error
      expect(logger).not_to have_received(:warn)
    end

    it "raises in development and test, naming the bad value and the valid keys" do
      CoPlan.configuration.default_theme = "hotdog-stand"

      %w[development test].each do |env|
        expect { described_class.check_default!(env: env.inquiry, logger: logger) }
          .to raise_error(ArgumentError, /"hotdog-stand".*Valid themes: #{described_class.keys.join(", ")}\./)
      end
    end

    it "only warns in production" do
      CoPlan.configuration.default_theme = "hotdog-stand"

      described_class.check_default!(env: "production".inquiry, logger: logger)
      expect(logger).to have_received(:warn).with(/"hotdog-stand".*Valid themes: #{described_class.keys.join(", ")}\./)
    end
  end

  it "resolves a stored choice to the theme it shows" do
    CoPlan.configuration.default_theme = "neutral"
    expect(described_class.resolve("classic").key).to eq("classic")
    expect(described_class.resolve("neutral").key).to eq("neutral")
    %w[default retired].each { |choice| expect(described_class.resolve(choice).key).to eq("neutral") }
    expect(described_class.resolve(nil).key).to eq("neutral")
    CoPlan.configuration.default_theme = "hotdog-stand"
    expect(described_class.resolve("default").key).to eq("classic")
  end

  it "never keys a theme \"default\", which a stored choice uses to follow the host" do
    expect(described_class.keys).not_to include(CoPlan::User::DEFAULT_APP_THEME)
  end

  it "has a stylesheet for every theme except Classic" do
    manifest = CoPlan::Engine.root.join("app/assets/stylesheets/coplan/application.css").read
    (described_class.keys - [ "classic" ]).each do |key|
      expect(CoPlan::Engine.root.join("app/assets/stylesheets/coplan/themes/#{key}.css")).to exist
      expect(manifest).to include(%(@import url("./themes/#{key}.css");))
    end
  end
end
