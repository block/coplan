class AddAgentProvenanceToLibraryEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_library_events, :agent_name, :string
    add_column :coplan_library_events, :api_token_id, :string, limit: 36
    add_index :coplan_library_events, :api_token_id
    add_foreign_key :coplan_library_events, :coplan_api_tokens, column: :api_token_id
  end
end
