module CoPlan
  class AutomatedReviewJob < ApplicationJob
    queue_as :default

    discard_on AiProviders::OpenAi::Error
    discard_on AiProviders::Anthropic::Error

    def perform(plan_id:, reviewer_id:, plan_version_id:, triggered_by: nil)
      plan = Plan.find(plan_id)
      reviewer = AutomatedPlanReviewer.find(reviewer_id)
      version = PlanVersion.find(plan_version_id)

      return unless reviewer.enabled?

      response = call_ai_provider(reviewer, version.content_markdown)
      feedback_items = Plans::ReviewResponseParser.call(response, plan_content: version.content_markdown)

      create_review_comments(plan, version, reviewer, feedback_items, triggered_by)
    end

    private

    def call_ai_provider(reviewer, content)
      system_prompt = Plans::ReviewPromptFormatter.call(reviewer_prompt: reviewer.prompt_text)
      provider_class = resolve_provider(reviewer.ai_provider)
      provider_class.call(
        system_prompt: system_prompt,
        user_content: content,
        model: reviewer.ai_model
      )
    end

    def resolve_provider(provider_name)
      case provider_name
      when "openai" then AiProviders::OpenAi
      when "anthropic" then AiProviders::Anthropic
      else raise ArgumentError, "Unknown AI provider: #{provider_name}"
      end
    end

    def create_review_comments(plan, version, reviewer, feedback_items, triggered_by)
      created_by = triggered_by || plan.created_by_user

      feedback_items.each do |item|
        thread = plan.comment_threads.create!(
          plan_version: version,
          created_by_user: created_by,
          anchor_text: item[:anchor_text],
          status: "pending"
        )

        thread.comments.create!(
          author_type: AutomatedPlanReviewer::ACTOR_TYPE,
          author_id: reviewer.id,
          body_markdown: item[:comment]
        )

        broadcast_new_thread(plan, thread)
      end
    end

    def broadcast_new_thread(plan, thread)
      Broadcaster.append_to(
        plan,
        target: "plan-threads",
        partial: "coplan/comment_threads/thread_popover",
        locals: { thread: thread, plan: plan }
      )
    end
  end
end
