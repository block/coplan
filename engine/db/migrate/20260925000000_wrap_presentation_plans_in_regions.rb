class WrapPresentationPlansInRegions < ActiveRecord::Migration[8.1]
  def up
    presentation_types = CoPlan::PlanType.where(behavior: "presentation")
    presentation_types.find_each do |type|
      template = type.template_content.to_s
      next if template.blank? || CoPlan::ContentRegions::Split.call(template).regions.any? { |region| region.kind == :presentation }

      type.update_columns(template_content: "::: {.presentation}\n\n#{template.rstrip}\n\n:::\n")
    end

    CoPlan::Plan.where(plan_type_id: presentation_types.select(:id)).find_each do |plan|
      plan.with_lock do
        content = plan.current_content.to_s
        next if content.empty? || CoPlan::ContentRegions::Split.call(content).regions.any? { |region| region.kind == :presentation }

        # This is a deployment backfill, not an interactive edit. Clear a
        # persisted lease under the plan lock so it cannot abort the schema
        # migration; an in-flight editor will see the new revision as stale.
        CoPlan::EditLease.where(plan_id: plan.id).delete_all
        CoPlan::Plans::ReplaceContent.call(
          plan: plan,
          new_content: "::: {.presentation}\n\n#{content.rstrip}\n\n:::\n",
          base_revision: plan.current_revision,
          actor_type: "system",
          actor_id: nil,
          change_summary: "Wrapped existing presentation in a content region",
          reason: "Presentation rendering now follows Markdown regions"
        )
      end
    end
    remove_column :coplan_plan_types, :behavior
  end

  def down
    add_column :coplan_plan_types, :behavior, :string, limit: 20, null: false, default: "document"
    # Versions are immutable; removing a later user edit on rollback would
    # corrupt history. The new renderer can read the wrapped content as-is.
  end
end
