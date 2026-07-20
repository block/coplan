class AddIconToCoplanPlanTypes < ActiveRecord::Migration[8.0]
  def change
    # Named icon from the built-in set (PlansHelper::PLAN_TYPE_ICONS
    # renders the SVG) — a name, not raw markup, so installs can brand
    # their document types without injecting arbitrary SVG.
    add_column :coplan_plan_types, :icon, :string, limit: 50
  end
end
