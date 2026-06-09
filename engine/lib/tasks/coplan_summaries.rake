namespace :coplan do
  namespace :summaries do
    # One-time backfill of AI summaries for plans created before the
    # summary infra (COPLAN-24, #118), which only fires on new
    # PlanVersion creates. Enqueues SummarizePlanJob for every plan
    # missing a summary; the job's sha-claim debounce makes this safe
    # to re-run.
    #
    # Throttled with a sleep between batches to avoid spiking OpenAI
    # cost/rate limits. Tune via env:
    #
    #   BATCH_SIZE=25 INTERVAL=5 bin/rails coplan:summaries:backfill
    #
    # Plans that already have a summary are excluded by the query;
    # plans with no current_plan_version (no content) are skipped.
    desc "Backfill AI summaries for plans missing one (COPLAN-31)"
    task backfill: :environment do
      batch_size = Integer(ENV["BATCH_SIZE"].presence || 25)
      interval   = Float(ENV["INTERVAL"].presence || 5)

      enqueued = 0
      skipped  = 0

      CoPlan::Plan.where(summary: nil).find_each(batch_size: batch_size) do |plan|
        if plan.current_plan_version_id.nil?
          skipped += 1
          next
        end

        CoPlan::SummarizePlanJob.perform_later(plan_id: plan.id)
        enqueued += 1

        sleep(interval) if interval.positive? && (enqueued % batch_size).zero?
      end

      puts "coplan:summaries:backfill — enqueued=#{enqueued} skipped=#{skipped} (skipped = no current_plan_version; already-summarized excluded by query)"
    end
  end
end
