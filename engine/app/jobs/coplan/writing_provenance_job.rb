module CoPlan
  # Backfill requested by details or a new edit to a legacy document. Document
  # GETs never replay history. Existing human input evidence is preserved.
  class WritingProvenanceJob < ApplicationJob
    queue_as :default

    def self.request(plan)
      Rails.cache.fetch([ "coplan/writing-provenance-build", plan.id, plan.current_revision ], expires_in: 1.minute) do
        perform_later(plan_id: plan.id)
        true
      end
    end

    def perform(plan_id:)
      plan = Plan.find_by(id: plan_id)
      return unless plan
      previous, revision = nil, 0
      loop do
        versions = plan.plan_versions.where("revision > ?", revision).reorder(:revision).limit(20).includes(:api_token).to_a
        break if versions.empty?
        versions.each do |version|
          existing = version.writing_provenance.to_h
          version.writing_identity = existing["write_source"]
          if version.actor_type == "human" && existing["format"] == Plans::WritingProvenance::FORMAT
            offset = 0
            version.input_sources = { "runs" => existing.fetch("runs").map { |length, key|
              text = version.content_markdown[offset, length]
              offset += length
              kind = existing.fetch("sources").fetch(key).fetch("kind") == "human" ? "human" : "unknown"
              [ text.encode(Encoding::UTF_16LE).bytesize / 2, kind ]
            } }
          end
          snapshot = Plans::WritingProvenance.call(version: version, previous: previous)
          version.update_columns(writing_provenance: snapshot)
          previous, revision = version, version.revision
        end
      end
      return unless previous
      updated = Plan.where(id: plan.id, current_plan_version_id: previous.id)
        .update_all(writing_provenance_summary: previous.writing_provenance.fetch("summary"))
      return unless updated.positive?
      Broadcaster.replace_to(plan.reload, target: "plan-header", partial: "coplan/plans/header", locals: { plan: plan })
    end
  end
end
