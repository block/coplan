# This migration comes from co_plan (originally 20260811000000)
class AddParentToCoplanApiTokens < ActiveRecord::Migration[8.1]
  def change
    # Session tokens are minted from a long-lived parent token, so a machine
    # keeps one secret and each agent run gets its own short-lived identity.
    # Revoking the parent has to revoke everything it minted, hence the link.
    add_column :coplan_api_tokens, :parent_id, :string, limit: 36
    add_index :coplan_api_tokens, [:parent_id, :revoked_at]
    add_foreign_key :coplan_api_tokens, :coplan_api_tokens, column: :parent_id
  end
end
