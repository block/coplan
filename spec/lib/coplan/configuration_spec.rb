require "rails_helper"

RSpec.describe Coplan::Configuration do
  subject(:config) { described_class.new }

  it "defaults to 300 initial delivery jobs per ten minutes" do
    expect(config.notification_fanout_limit).to eq(300)
    expect(config.notification_fanout_window).to eq(600)
  end

  it "accepts a host limit, a whole-second duration, and disabling with nil" do
    config.notification_fanout_limit = 50
    config.notification_fanout_window = 2.minutes
    expect(config.notification_fanout_limit).to eq(50)
    expect(config.notification_fanout_window).to eq(120)
    config.notification_fanout_limit = nil
    expect(config.notification_fanout_limit).to be_nil
  end

  it "rejects invalid limits before the host starts serving requests" do
    [ 0, -1, 1.5, "300", false ].each do |value|
      expect { config.notification_fanout_limit = value }.to raise_error(ArgumentError)
    end
    expect(config.notification_fanout_limit).to eq(300)
  end

  it "rejects invalid windows before the host starts serving requests" do
    [ nil, 0, -1, 0.5.seconds, Float::INFINITY, Float::NAN, Complex(1, 2), "600" ].each do |value|
      expect { config.notification_fanout_window = value }.to raise_error(ArgumentError)
    end
    expect(config.notification_fanout_window).to eq(600)
  end
end
