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
    expect(described_class.default).to eq("classic")
  end

  it "uses the host's configured default" do
    CoPlan.configuration.default_theme = :classic
    expect(described_class.default).to eq("classic")
  end

  it "falls back to Classic for an unknown theme" do
    CoPlan.configuration.default_theme = "hotdog-stand"
    expect(described_class.default).to eq("classic")
    expect(described_class.find("hotdog-stand")).to be_nil
  end

  it "has a stylesheet for every theme except Classic" do
    manifest = CoPlan::Engine.root.join("app/assets/stylesheets/coplan/application.css").read
    (described_class.keys - [ "classic" ]).each do |key|
      expect(CoPlan::Engine.root.join("app/assets/stylesheets/coplan/themes/#{key}.css")).to exist
      expect(manifest).to include(%(@import url("./themes/#{key}.css");))
    end
  end
end
