module CoPlan
  # Regenerates a plan's AI-generated summary.
  #
  # Enqueued from PlanVersion#after_create_commit. Debounced via
  # `plan.summary_content_sha256`: if the plan's current content sha
  # already matches the sha the existing summary was generated from,
  # the job no-ops. This is safe under rapid back-to-back edits — each
  # PlanVersion enqueues a job, but only one ends up calling the AI.
  #
  # AI provider errors are discarded rather than retried — a stale
  # summary is fine, and the next PlanVersion will trigger another
  # attempt.
  class SummarizePlanJob < ApplicationJob
    PROMPT_PATH = CoPlan::Engine.root.join("prompts", "summarize.md").freeze

    queue_as :default

    discard_on CoPlan::Ai::Error

    def perform(plan_id:)
      plan = Plan.find_by(id: plan_id)
      return unless plan

      current_sha = plan.current_plan_version&.content_sha256
      return if current_sha.blank?
      return if plan.summary_content_sha256 == current_sha

      summary = generate_summary(plan)
      return if summary.blank?

      persist_summary(plan, summary, current_sha)
    end

    private

    def generate_summary(plan)
      content = plan.current_content
      return nil if content.blank?

      CoPlan::Ai.call(
        system_prompt: File.read(PROMPT_PATH),
        user_content: content
      ).to_s.strip.presence
    end

    # Persist the summary only if the plan's current content sha still
    # matches the sha we generated from. Without this check, a slow job
    # that started against revision N could overwrite a fresher summary
    # generated against revision N+1 — AI calls take seconds, plenty of
    # time for a newer version to land first.
    def persist_summary(plan, summary, expected_sha)
      plan.with_lock do
        plan.reload
        return if plan.current_plan_version&.content_sha256 != expected_sha

        plan.update!(
          summary: summary,
          summary_generated_at: Time.current,
          summary_content_sha256: expected_sha
        )
      end
    end
  end
end
