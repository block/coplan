require "rails_helper"

RSpec.describe Coplan::UiLocale do
  def select(header, locales: %i[en es], default: :en)
    described_class.select(header, locales: locales, default: default)
  end

  it "negotiates weighted preferences, regional tags and case" do
    expect(select("fr-CA, en-GB;q=0.7, ES-mx;q=0.9")).to eq(:es)
    expect(select("es-MX", locales: %i[en es es-MX])).to eq(:"es-MX")
  end

  it "preserves browser order for equal weights" do
    expect(select("es, en")).to eq(:es)
    expect(select("en, es")).to eq(:en)
  end

  it "skips explicit exclusions and honors specific ranges over wildcards" do
    expect(select("es;q=0, *;q=0.5", default: :es)).to eq(:en)
    expect(select("es-MX, es;q=0, en;q=0.5")).to eq(:en)
    expect(select("es;q=0.9, *")).to eq(:en)
  end

  it "uses the configured fallback for unsupported, absent, invalid or oversized preferences" do
    expect(select("fr", default: :es)).to eq(:es)
    expect(select(nil, default: :es)).to eq(:es)
    expect(select("es;q=broken, es;q=2, es;q=0")).to eq(:en)
    expect(select("es," * 1500)).to eq(:en)
  end

  it "uses a host's only enabled locale immediately" do
    expect(select("es", locales: %i[en])).to eq(:en)
  end
end
