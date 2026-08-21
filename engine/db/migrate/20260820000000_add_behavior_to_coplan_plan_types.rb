class AddBehaviorToCoplanPlanTypes < ActiveRecord::Migration[8.1]
  # Behavior is a column rather than a name match: type names are
  # host-editable data, and renaming "Presentation" must not strip a deck
  # of its deck rendering.
  def change
    add_column :coplan_plan_types, :behavior, :string, limit: 20, null: false, default: "document"
  end
end
