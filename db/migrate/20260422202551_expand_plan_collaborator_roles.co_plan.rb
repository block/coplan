# This migration comes from co_plan (originally 20260422000000)
class ExpandPlanCollaboratorRoles < ActiveRecord::Migration[8.0]
  def change
    add_column :coplan_plan_collaborators, :approved_at, :datetime
    add_column :coplan_plan_collaborators, :highlighted_reason, :text
  end
end
