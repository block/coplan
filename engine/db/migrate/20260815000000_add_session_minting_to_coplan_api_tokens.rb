class AddSessionMintingToCoplanApiTokens < ActiveRecord::Migration[8.1]
  def change
    # Session tokens are minted from a long-lived parent token, so a machine
    # keeps one secret and each agent run gets its own short-lived identity.
    # Revoking the parent has to revoke everything it minted, hence the link.
    #
    # Guarded: databases set up via db:schema:load while main's schema.rb
    # carried these columns without a migration (and dev databases that ran
    # the agent-collaboration branch) already have them.
    unless column_exists?(:coplan_api_tokens, :parent_id)
      add_column :coplan_api_tokens, :parent_id, :string, limit: 36
    end
    unless index_exists?(:coplan_api_tokens, [ :parent_id, :revoked_at ])
      add_index :coplan_api_tokens, [ :parent_id, :revoked_at ]
    end
    unless foreign_key_exists?(:coplan_api_tokens, column: :parent_id)
      add_foreign_key :coplan_api_tokens, :coplan_api_tokens, column: :parent_id
    end

    # Which agent this token speaks for ("Claude", "Amp"). Attribution rows
    # written with the token inherit it, the same way comments carry a
    # per-comment agent_name.
    unless column_exists?(:coplan_api_tokens, :agent_name)
      add_column :coplan_api_tokens, :agent_name, :string
    end
  end
end
