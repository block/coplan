module CoPlan
  module MigrationSupport
    # Migration-only support for UnifyDocumentTitles (20261105220000).
    # Not a runtime API. Retain until that migration is retired from supported
    # upgrade paths; deleting it earlier would break existing host upgrades.
    # Idempotent, one locked transaction per plan. Historical versions are
    # never rewritten. A lease stops the backfill; rerunning resumes safely.
    class BackfillDocumentTitles
      def self.call
        # Boot initializers can cache the schema before earlier migrations add
        # columns used by the current model's validations and version writes.
        Plan.reset_column_information
        Plan.find_each do |plan|
          plan.with_lock do
            content = MarkdownDocumentTitle.normalize(plan.current_content, fallback: plan.title, override: true)
            if content == plan.current_content
              # A previous attempt may have committed the version before its
              # reference-extraction callback failed. Repair that derived data.
              References::ExtractFromContent.call(plan: plan, content: content)
              next
            end

            Plans::ReplaceContent.call(plan: plan, new_content: content, base_revision: plan.current_revision,
              actor_type: "system", actor_id: nil, change_summary: "Use the document heading as its title")
          end
        end
        PlanType.find_each do |type|
          type.with_lock do
            content = MarkdownDocumentTitle.normalize(type.template_content, fallback: "Document title")
            type.update!(template_content: content) if content != type.template_content
          end
        end
      end
    end
  end
end
