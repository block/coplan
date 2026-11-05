# This migration comes from co_plan (originally 20261105220000)
class UnifyDocumentTitles < ActiveRecord::Migration[8.1]
  def up
    change_column :coplan_plans, :title, :text, null: false
    CoPlan::Plans::BackfillDocumentTitles.call
  end

  def down
    # These are attributed content versions, not disposable schema data.
    raise ActiveRecord::IrreversibleMigration, "Document title versions remain in plan history"
  end
end
