# This migration comes from co_plan (originally 20261006000000)
class MoveUserSettingsOutOfMetadata < ActiveRecord::Migration[8.1]
  # Use a migration-local model so future User callbacks and validations do
  # not change how historical preferences are copied.
  class User < ActiveRecord::Base
    self.table_name = "coplan_users"
  end

  def up
    add_column :coplan_users, :theme_preference, :string, null: false, default: "system"
    add_column :coplan_users, :voice_hotkey, :string, null: false, default: "ctrl_space"
    User.reset_column_information

    User.find_each do |user|
      metadata = user.metadata.is_a?(Hash) ? user.metadata : {}
      theme = metadata["theme_preference"]
      hotkey = metadata["voice_hotkey"]
      user.update_columns(
        theme_preference: %w[system light dark].include?(theme) ? theme : "system",
        voice_hotkey: %w[ctrl_space shift alt off].include?(hotkey) ? hotkey : "ctrl_space"
      )
    end
  end

  def down
    User.reset_column_information
    User.find_each do |user|
      metadata = user.metadata.is_a?(Hash) ? user.metadata : {}
      user.update_columns(metadata: metadata.merge(
        "theme_preference" => user.theme_preference,
        "voice_hotkey" => user.voice_hotkey
      ))
    end

    remove_column :coplan_users, :voice_hotkey
    remove_column :coplan_users, :theme_preference
    User.reset_column_information
  end
end
