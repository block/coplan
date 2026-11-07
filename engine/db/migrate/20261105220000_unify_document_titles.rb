require "coplan/migration_support/backfill_document_titles"

class UnifyDocumentTitles < ActiveRecord::Migration[8.1]
  # Keep the backfill resumable per plan on PostgreSQL as well as MySQL.
  disable_ddl_transaction!

  def up
    change_column :coplan_plans, :title, :text, null: false
    CoPlan::MigrationSupport::BackfillDocumentTitles.call
  end

  def down
    # These are attributed content versions, not disposable schema data.
    raise ActiveRecord::IrreversibleMigration, "Document title versions remain in plan history"
  end
end
