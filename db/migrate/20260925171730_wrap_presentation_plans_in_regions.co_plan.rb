# This migration comes from co_plan (originally 20260925000000)
class WrapPresentationPlansInRegions < ActiveRecord::Migration[8.1]
  PRESENTATION_MARKER = "_coplan_previous_presentation_behavior".freeze

  def up
    presentation_types = CoPlan::PlanType.where(behavior: "presentation")
    presentation_types.find_each do |type|
      template = type.template_content.to_s
      metadata = type.metadata.to_h.merge(PRESENTATION_MARKER => { "template_content" => type.template_content })
      if template.blank? || CoPlan::ContentRegions::Split.call(template).regions.any? { |region| region.kind == :presentation }
        type.update_columns(metadata: metadata)
      else
        type.update_columns(metadata: metadata, template_content: "::: {.presentation}\n\n#{template.rstrip}\n\n:::\n")
      end
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
    CoPlan::PlanType.find_each do |type|
      metadata = type.metadata.to_h
      previous = metadata.delete(PRESENTATION_MARKER)
      next unless previous

      type.update_columns(behavior: "presentation", metadata: metadata, template_content: previous["template_content"])
      CoPlan::Plan.where(plan_type_id: type.id).find_each do |plan|
        plan.with_lock do
          next unless plan.current_plan_version&.reason == "Presentation rendering now follows Markdown regions"

          original = plan.plan_versions.find_by(revision: plan.current_revision - 1)
          next unless original

          CoPlan::EditLease.where(plan_id: plan.id).delete_all
          CoPlan::Plans::ReplaceContent.call(
            plan: plan,
            new_content: original.content_markdown,
            base_revision: plan.current_revision,
            actor_type: "system",
            actor_id: nil,
            change_summary: "Restored presentation content for rollback",
            reason: "Presentation region migration rolled back"
          )
        end
      end
    end
    # Later user edits remain immutable; only the exact migration revision
    # is reversed, and that reversal is itself a new version.
  end
end
