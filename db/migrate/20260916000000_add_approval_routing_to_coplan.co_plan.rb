# This migration comes from co_plan (originally 20260916000000)
class AddApprovalRoutingToCoplan < ActiveRecord::Migration[8.0]
  def change
    add_column :coplan_plans, :touched_files, :json
    add_column :coplan_plan_collaborators, :routing_source, :string
    add_column :coplan_plan_collaborators, :routing_metadata, :json
    add_index :coplan_plan_collaborators, [ :plan_id, :routing_source ], name: "index_coplan_collaborators_on_plan_and_routing_source"
  end
end
