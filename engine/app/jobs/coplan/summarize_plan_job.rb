module CoPlan
  # Wait for a quiet period before summarizing the current plan version.
  # The atomic content claim deduplicates jobs that reach the same revision.
  # AI failures keep their claim so jobs for that content won't retry the call.
  class SummarizePlanJob < ApplicationJob
    DEBOUNCE_DELAY = 1.minute
    PROMPT_PATH = CoPlan::Engine.root.join("prompts", "summarize.md").freeze

    queue_as :default

    discard_on CoPlan::Ai::Error

    def perform(plan_id:, version_id: nil)
      plan = Plan.find_by(id: plan_id)
      return unless plan
      return if version_id && version_id != plan.current_plan_version_id

      version = plan.current_plan_version
      return if version&.content_sha256.blank?

      # Backfill jobs and jobs queued before deployment can arrive early.
      ready_at = version.created_at + DEBOUNCE_DELAY
      if ready_at.future?
        self.class.set(wait_until: ready_at).perform_later(plan_id: plan.id, version_id: version.id)
        return
      end

      return unless claim_version(plan, version)

      summary = generate_summary(version.content_markdown)
      return if summary.blank?

      persist_summary(plan, summary, version.content_sha256)
    end

    private

    # Only claim a version that is still current. The conditional update also
    # lets just one worker call the AI for the same content.
    def claim_version(plan, version)
      Plan.where(id: plan.id, current_plan_version_id: version.id)
          .where("summary_content_sha256 IS NULL OR summary_content_sha256 != ?", version.content_sha256)
          .update_all(summary_content_sha256: version.content_sha256).positive?
    end

    def generate_summary(content)
      return nil if content.blank?

      CoPlan::Ai.call(
        system_prompt: File.read(PROMPT_PATH),
        user_content: content,
        intensity: :low
      ).to_s.strip.presence
    end

    # Keep the previous summary visible until a call succeeds. A newer
    # claim supersedes this result if another call has already started.
    def persist_summary(plan, summary, expected_sha)
      Plan.where(id: plan.id, summary_content_sha256: expected_sha)
          .update_all(summary: summary, summary_generated_at: Time.current)
    end
  end
end
