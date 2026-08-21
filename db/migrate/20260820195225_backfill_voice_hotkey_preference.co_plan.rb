# This migration comes from co_plan (originally 20260820000000)
class BackfillVoiceHotkeyPreference < ActiveRecord::Migration[8.1]
  # Push-to-talk used to be Shift, for everyone, with no way to change it.
  # It is now a setting, and the default for anyone new is Ctrl+Space —
  # a deliberate chord that can open the microphone the instant it's
  # pressed, where a bare Shift has to wait out a hold delay to tell
  # talking from typing a capital.
  #
  # Nobody's hands should have to relearn that on a deploy, so everyone
  # who already exists is written down as a Shift user explicitly. From
  # here on, "no preference recorded" means "arrived after the setting
  # existed" and reads as Ctrl+Space.
  #
  # Idempotent: only users with no voice_hotkey recorded are touched.
  def up
    CoPlan::User.find_each do |user|
      metadata = user.metadata || {}
      next if metadata.key?("voice_hotkey")

      user.update_column(:metadata, metadata.merge("voice_hotkey" => "shift")) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    CoPlan::User.find_each do |user|
      metadata = user.metadata
      next unless metadata.is_a?(Hash) && metadata["voice_hotkey"] == "shift"

      user.update_column(:metadata, metadata.except("voice_hotkey")) # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
