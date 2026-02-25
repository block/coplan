class AddTokenPrefixToApiTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :api_tokens, :token_prefix, :string, limit: 8
  end
end
