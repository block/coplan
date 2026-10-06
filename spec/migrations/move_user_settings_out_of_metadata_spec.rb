require "rails_helper"
require CoPlan::Engine.root.join("db/migrate/20261006000000_move_user_settings_out_of_metadata.rb")

RSpec.describe MoveUserSettingsOutOfMetadata do
  subject(:migration) { described_class.new }

  # The test schema already includes the columns. Exercise the real data
  # migration without changing the shared schema inside transactional specs.
  before do
    allow(migration).to receive(:add_column)
    allow(migration).to receive(:remove_column)
  end

  it "copies every supported legacy preference without changing directory data" do
    users = %w[ctrl_space shift alt off].each_with_index.map do |hotkey, index|
      create(:coplan_user, metadata: {
        "theme_preference" => %w[system light dark][index % 3],
        "voice_hotkey" => hotkey,
        "department" => "Engineering"
      })
    end

    migration.up

    users.each do |user|
      original = user.metadata.deep_dup
      user.reload
      expect(user.theme_preference).to eq(original["theme_preference"])
      expect(user.voice_hotkey).to eq(original["voice_hotkey"])
      expect(user.metadata).to eq(original)
    end
  end

  it "uses the current defaults for missing or invalid legacy preferences" do
    users = [ {}, { "theme_preference" => "invalid", "voice_hotkey" => "F13" },
      { "theme_preference" => nil, "voice_hotkey" => nil } ].map do |metadata|
      create(:coplan_user, metadata: metadata)
    end

    migration.up

    users.each do |user|
      expect(user.reload.theme_preference).to eq("system")
      expect(user.voice_hotkey).to eq("ctrl_space")
    end
  end

  it "copies the latest settings back on rollback, preserving host metadata" do
    user = create(:coplan_user, theme_preference: "light", voice_hotkey: "off",
      metadata: { "department" => "Engineering", "theme_preference" => "dark" })

    migration.down

    expect(user.reload.metadata).to eq(
      "department" => "Engineering", "theme_preference" => "light", "voice_hotkey" => "off"
    )
  end
end
