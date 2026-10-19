module CoPlan
  class WritingProvenanceJob < ApplicationJob
    queue_as :default
    queue_with_priority 20
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def self.request(plan)
      token = Plans::WritingProvenanceBackfill.claim(plan)
      return false unless token
      ActiveRecord.after_all_transactions_commit do
        begin
          job = perform_later(plan_id: plan.id, token: token)
          raise ActiveJob::EnqueueError, "Writing provenance job was not enqueued" unless job&.successfully_enqueued?
        rescue StandardError => error
          Plans::WritingProvenanceBackfill.release(plan, token)
          Rails.logger.warn("Writing provenance enqueue failed for #{plan.id}: #{error.class}")
        end
      end
      true
    end

    def perform(plan_id:, token: nil, restart: false)
      plan = Plan.find_by(id: plan_id)
      return unless plan
      token ||= Plans::WritingProvenanceBackfill.claim(plan, restart: restart)
      return unless token
      if Plans::WritingProvenanceBackfill.call(plan: plan, token: token)
        self.class.perform_later(plan_id: plan.id, token: token)
      end
    end
  end
end
