module CoPlan
  # Scan without loading content, and revisit pending leases to recover crashes.
  class WritingProvenanceBackfillJob < ApplicationJob
    queue_as :default
    queue_with_priority 20
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def self.start
      return unless Plan.table_exists? && Plan.column_names.include?("writing_provenance_backfill")
      perform_later
    rescue StandardError => error
      Rails.logger.warn("Writing provenance backfill will start on the next boot: #{error.class}")
    end

    def perform(after_id: nil, pending: false)
      plans = Plan.select(:id, :metadata, :current_revision, :writing_provenance_backfill, :writing_provenance_summary).order(:id)
      plans = plans.where("id > ?", after_id) if after_id
      batch = plans.limit(100).to_a
      batch.each do |plan|
        next unless Plans::WritingProvenanceBackfill.pending?(plan)
        pending = true
        WritingProvenanceJob.request(plan)
      end
      if batch.size == 100
        self.class.perform_later(after_id: batch.last.id, pending: pending)
      elsif pending
        self.class.set(wait: Plans::WritingProvenanceBackfill::LEASE + 30.seconds).perform_later
      end
    end
  end
end
