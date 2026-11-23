# This migration comes from coplan (originally 20260925000000)
class WrapPresentationPlansInRegions < ActiveRecord::Migration[8.1]
  PRESENTATION_MARKER = "_coplan_previous_presentation_behavior".freeze
  MIGRATION_REASON = "Presentation rendering now follows Markdown regions".freeze
  ROLLBACK_REASON = "Presentation region migration rolled back".freeze

  def up
    presentation_types = Coplan::PlanType.where(behavior: "presentation")
    presentation_types.find_each do |type|
      template = type.template_content.to_s
      metadata = type.metadata.to_h
      metadata[PRESENTATION_MARKER] ||= { "template_content" => type.template_content }
      if template.blank? || Coplan::ContentRegions::Split.call(template).regions.any? { |region| region.kind == :presentation }
        type.update_columns(metadata: metadata)
      else
        type.update_columns(metadata: metadata, template_content: "::: {.presentation}\n\n#{template.rstrip}\n\n:::\n")
      end
    end

    Coplan::Plan.where(plan_type_id: presentation_types.select(:id)).find_each do |plan|
      plan.with_lock do
        content = plan.current_content.to_s
        next if content.empty? || Coplan::ContentRegions::Split.call(content).regions.any? { |region| region.kind == :presentation }

        # This is a deployment backfill, not an interactive edit. Clear a
        # persisted lease under the plan lock so it cannot abort the schema
        # migration; an in-flight editor will see the new revision as stale.
        Coplan::EditLease.where(plan_id: plan.id).delete_all
        Coplan::Plans::ReplaceContent.call(
          plan: plan,
          new_content: "::: {.presentation}\n\n#{content.rstrip}\n\n:::\n",
          base_revision: plan.current_revision,
          actor_type: "system",
          actor_id: nil,
          change_summary: "Wrapped existing presentation in a content region",
          reason: MIGRATION_REASON
        )
      end
    end
    remove_column :coplan_plan_types, :behavior
  end

  def down
    ensure_no_edited_presentations!
    add_column :coplan_plan_types, :behavior, :string, limit: 20, null: false, default: "document" unless column_exists?(:coplan_plan_types, :behavior)
    Coplan::PlanType.reset_column_information
    Coplan::PlanType.find_each do |type|
      metadata = type.metadata.to_h
      previous = metadata[PRESENTATION_MARKER]
      next unless previous

      Coplan::Plan.where(plan_type_id: type.id).find_each do |plan|
        plan.with_lock do
          next unless plan.current_plan_version&.reason == MIGRATION_REASON

          original = plan.plan_versions.find_by(revision: plan.current_revision - 1)
          raise ActiveRecord::IrreversibleMigration, "Missing original version for presentation plan #{plan.id}" unless original

          Coplan::EditLease.where(plan_id: plan.id).delete_all
          Coplan::Plans::ReplaceContent.call(
            plan: plan,
            new_content: original.content_markdown,
            base_revision: plan.current_revision,
            actor_type: "system",
            actor_id: nil,
            change_summary: "Restored presentation content for rollback",
            reason: ROLLBACK_REASON
          )
        end
      end
      metadata.delete(PRESENTATION_MARKER)
      type.update_columns(behavior: "presentation", metadata: metadata, template_content: previous["template_content"])
    end
    # Only the exact migration revision is reversed, as a new version.
  end

  private

  def ensure_no_edited_presentations!
    Coplan::Plan.find_each do |plan|
      migrated = plan.plan_versions.where(reason: MIGRATION_REASON).order(revision: :desc).first
      next if migrated && plan.current_plan_version_id == migrated.id && plan.plan_type.metadata.to_h.key?(PRESENTATION_MARKER)
      current = plan.current_plan_version
      next if migrated && current&.reason == ROLLBACK_REASON && current.revision == migrated.revision + 1
      next unless migrated || Coplan::ContentRegions::Split.call(plan.current_content).regions.any? { |region| region.kind == :presentation }

      raise ActiveRecord::IrreversibleMigration,
        "Plan #{plan.id} has content incompatible with the legacy renderer; resolve it before rolling back"
    end
  end
end
