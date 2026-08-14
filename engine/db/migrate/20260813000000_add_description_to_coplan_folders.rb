class AddDescriptionToCoplanFolders < ActiveRecord::Migration[8.1]
  def change
    # A short human/agent-readable statement of what belongs in the folder
    # (e.g. "Active Q3 work — move to Done when shipped"). Surfaced in the
    # library overview API so agents can organize by meaning, not just name.
    add_column :coplan_folders, :description, :string, limit: 255
  end
end
