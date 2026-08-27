class ExpandCoplanReferenceUrls < ActiveRecord::Migration[8.1]
  def up
    if connection.adapter_name == "PostgreSQL"
      remove_url_index_and_expand_column
      add_digest_column
      add_digest_index
    else
      add_digest_column
      add_digest_index
      remove_url_index_and_expand_column
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "reference URLs may exceed the former 255-character limit"
  end

  private

  def add_digest_column
    add_column :coplan_references, :url_digest, :virtual, type: :string, limit: 64,
      as: digest_expression, stored: true
  end

  def add_digest_index
    add_index :coplan_references, [ :plan_id, :url_digest ], unique: true,
      name: "index_coplan_references_on_plan_id_and_url_digest"
  end

  def remove_url_index_and_expand_column
    remove_index :coplan_references, column: [ :plan_id, :url ]
    change_column :coplan_references, :url, :text, null: false
  end

  def digest_expression
    case connection.adapter_name
    when "Mysql2"
      "SHA2(url, 256)"
    when "PostgreSQL"
      "encode(sha256(url::bytea), 'hex')"
    else
      raise "Unsupported database adapter: #{connection.adapter_name}"
    end
  end
end
