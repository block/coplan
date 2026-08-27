require "digest"

class ExpandCoplanReferenceUrls < ActiveRecord::Migration[8.1]
  class MigrationReference < ActiveRecord::Base
    self.table_name = "coplan_references"
  end

  def up
    add_column :coplan_references, :url_digest, :string, limit: 64

    MigrationReference.reset_column_information
    MigrationReference.find_each do |reference|
      reference.update_column(:url_digest, Digest::SHA256.hexdigest(reference.url))
    end

    # Keep this nullable for rolling-deploy compatibility: old application
    # processes do not populate the digest. The new model fills any missing
    # digest before validation, including rows written during this migration.
    remove_index :coplan_references, column: [ :plan_id, :url ]
    change_column :coplan_references, :url, :text, null: false
    add_index :coplan_references, [ :plan_id, :url_digest ], unique: true,
      name: "index_coplan_references_on_plan_id_and_url_digest"
  end

  def down
    remove_index :coplan_references, name: "index_coplan_references_on_plan_id_and_url_digest"
    change_column :coplan_references, :url, :string, null: false
    add_index :coplan_references, [ :plan_id, :url ], unique: true
    remove_column :coplan_references, :url_digest
  end
end
