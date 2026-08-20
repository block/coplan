# This migration comes from co_plan (originally 20260820000000)
class AddBehaviorToCoplanPlanTypes < ActiveRecord::Migration[8.1]
  # Behavior is a column rather than a name match: type names are
  # host-editable data, and renaming "Slideshow" must not strip a deck of
  # its deck rendering.
  def change
    add_column :coplan_plan_types, :behavior, :string, limit: 20, null: false, default: "document"
  end
end
