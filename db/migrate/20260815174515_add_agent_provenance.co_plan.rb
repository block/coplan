# This migration comes from co_plan (originally 20260815000002)
class AddAgentProvenance < ActiveRecord::Migration[8.1]
  def change
    # Identity facts (harness, harness version, model, …) live on the token,
    # captured at mint time — schemaless, because the set of facts worth
    # recording grows faster than anyone wants to migrate three tables.
    add_column :coplan_api_tokens, :metadata, :json

    # Attribution rows keep agent_name as the display string, and point at
    # the token for everything else. actor/author stays the human.
    add_column :coplan_plan_versions, :api_token_id, :string, limit: 36
    add_column :coplan_plan_events, :api_token_id, :string, limit: 36
    add_column :coplan_comments, :api_token_id, :string, limit: 36

    add_index :coplan_plan_versions, :api_token_id
    add_index :coplan_plan_events, :api_token_id
    add_index :coplan_comments, :api_token_id

    add_foreign_key :coplan_plan_versions, :coplan_api_tokens, column: :api_token_id
    add_foreign_key :coplan_plan_events, :coplan_api_tokens, column: :api_token_id
    add_foreign_key :coplan_comments, :coplan_api_tokens, column: :api_token_id
  end
end
