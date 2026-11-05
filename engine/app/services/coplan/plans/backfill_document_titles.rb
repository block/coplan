module CoPlan
  module Plans
    # Idempotent, one locked transaction per plan. Historical versions are
    # never rewritten. A lease stops the backfill; rerunning resumes safely.
    class BackfillDocumentTitles
      def self.call
        Plan.find_each do |plan|
          plan.with_lock do
            content = DocumentTitle.call(plan.current_content, fallback: plan.title, override: true)
            next if content == plan.current_content

            ReplaceContent.call(plan: plan, new_content: content, base_revision: plan.current_revision,
              actor_type: "system", actor_id: nil, change_summary: "Use the document heading as its title")
          end
        end
        PlanType.find_each do |type|
          type.with_lock do
            content = DocumentTitle.call(type.template_content, fallback: "Document title")
            type.update!(template_content: content) if content != type.template_content
          end
        end
      end
    end
  end
end
