module CoPlan
  module Plans
    # No browser-session lease. The plan row is locked only while comparing
    # the immutable base, applying the surgical diff and committing a version.
    class SaveHumanDraft
      def self.call(plan:, content:, base_revision:, actor:, metadata: {}, base_metadata: {}, overwrite_revision: nil, change_summary: nil)
        plan.with_lock do
          # Leases from the first editor prototype are obsolete. Old tabs still
          # send revision-guarded saves; retiring a lease never discards a draft.
          plan.edit_lease&.destroy! if plan.edit_lease&.holder_type == "human"
          EditLease.enforce!(plan: plan)
          base = plan.plan_versions.find_by(revision: base_revision)
          raise MergeText::Conflict, "The draft's base version is unavailable" unless base
          current = plan.current_content.to_s
          if overwrite_revision.present?
            raise MergeText::Conflict, "The document changed again; review the latest version" unless plan.current_revision == overwrite_revision.to_i
            merged = content
          else
            merged = MergeText.call(base: base.content_markdown, local: content, remote: current)
          end
          updates = {}
          metadata.each do |key, value|
            current_value = key == :title ? plan.title : plan.tag_names.join(", ")
            baseline = base_metadata[key]
            # Older clients omit a metadata baseline: only accept unchanged
            # metadata when they are stale. New clients always include it.
            if baseline.nil? && base_revision != plan.current_revision && value != current_value
              raise MergeText::Conflict, "The document's #{key} may have changed"
            end
            baseline ||= current_value
            next if value == baseline
            if current_value != baseline && current_value != value
              raise MergeText::Conflict, "Both edits change the document's #{key}"
            end
            updates[key] = value
          end
          # Validate and persist metadata before content broadcasts, within the
          # same transaction. A validation failure must never publish a draft.
          yield updates if block_given?
          result = ReplaceContent.call(plan: plan, new_content: merged, base_revision: plan.current_revision,
            actor_type: "human", actor_id: actor.id, change_summary: change_summary.presence || "Edited in web UI",
            granularity: :character)
          result
        end
      end
    end
  end
end
