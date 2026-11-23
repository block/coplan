# This migration comes from coplan (originally 20261016000000)
class AddWritingProvenance < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_plan_versions, :writing_provenance, :json
    add_column :coplan_plans, :writing_provenance_summary, :json
  end
end
