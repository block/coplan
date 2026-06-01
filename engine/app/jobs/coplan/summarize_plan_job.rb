module CoPlan
  # Regenerates a plan's AI-generated summary.
  #
  # Enqueued from PlanVersion#after_create_commit. Debounced via
  # `plan.summary_content_sha256`: each job atomically "claims" the
  # current content sha before calling the AI. Two workers that wake
  # up against the same plan-and-sha will race on the claim — only one
  # wins, the other no-ops. Without the atomic claim, both would pass
  # a naive pre-check, both call the AI, and waste a full AI request.
  #
  # AI errors are discarded rather than retried — a stale summary is
  # fine, and the next PlanVersion will trigger another attempt. The
  # claim survives the failure, which is intentional: we'd rather skip
  # this revision than retry a broken prompt in a loop.
  class SummarizePlanJob < ApplicationJob
    PROMPT_PATH = CoPlan::Engine.root.join("prompts", "summarize.md").freeze

    queue_as :default

    discard_on CoPlan::Ai::Error

    def perform(plan_id:)
      plan = Plan.find_by(id: plan_id)
      return unless plan

      current_sha = plan.current_plan_version&.content_sha256
      return if current_sha.blank?

      return unless claim_sha(plan, current_sha)

      summary = generate_summary(plan)
      return if summary.blank?

      persist_summary(plan, summary, current_sha)
    end

    private

    # Atomic claim: set summary_content_sha256 = current_sha only if it
    # isn't already current_sha. Returns true if THIS job won the claim.
    #
    # Using a single conditional UPDATE (one round-trip, atomic at the
    # DB) means concurrent workers can't both pass the check and both
    # call the AI — exactly one row update succeeds per sha.
    def claim_sha(plan, current_sha)
      claimed = Plan.where(id: plan.id)
                    .where("summary_content_sha256 IS NULL OR summary_content_sha256 != ?", current_sha)
                    .update_all(summary_content_sha256: current_sha)
      claimed.positive?
    end

    def generate_summary(plan)
      content = plan.current_content
      return nil if content.blank?

      CoPlan::Ai.call(
        system_prompt: File.read(PROMPT_PATH),
        user_content: content
      ).to_s.strip.presence
    end

    # Write the summary only if our claim is still current — if a newer
    # version landed mid-flight, a fresher job has already re-claimed
    # the sha and we'd be stomping its work.
    def persist_summary(plan, summary, expected_sha)
      Plan.where(id: plan.id, summary_content_sha256: expected_sha)
          .update_all(summary: summary, summary_generated_at: Time.current)
    end
  end
end
