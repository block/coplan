class AddAppThemeToCoplanUsers < ActiveRecord::Migration[8.1]
  # "default" follows the host's config.default_theme (docs/THEMES.md).
  def change
    add_column :coplan_users, :app_theme, :string, null: false, default: "default"
  end
end
