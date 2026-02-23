class AutomatedReviewJob < ApplicationJob
  queue_as :default

  discard_on AiProviders::OpenAi::Error
  discard_on AiProviders::Anthropic::Error

  def perform(plan_id:, reviewer_id:, triggered_by: nil)
    plan = Plan.find(plan_id)
    reviewer = AutomatedPlanReviewer.find(reviewer_id)
    version = plan.current_plan_version

    return unless version
    return unless reviewer.enabled?

    response = call_ai_provider(reviewer, version.content_markdown)

    create_review_comment(plan, version, reviewer, response, triggered_by)
  end

  private

  def call_ai_provider(reviewer, content)
    provider_class = resolve_provider(reviewer.ai_provider)
    provider_class.call(
      system_prompt: reviewer.prompt_text,
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

  def create_review_comment(plan, version, reviewer, response, triggered_by)
    thread = plan.comment_threads.create!(
      organization: plan.organization,
      plan_version: version,
      created_by_user: triggered_by || plan.created_by_user,
      status: "open"
    )

    thread.comments.create!(
      organization: plan.organization,
      author_type: AutomatedPlanReviewer::ACTOR_TYPE,
      author_id: reviewer.id,
      body_markdown: response
    )

    broadcast_new_thread(plan, thread)
  end

  def broadcast_new_thread(plan, thread)
    Turbo::StreamsChannel.broadcast_prepend_to(
      plan,
      target: "comment-threads",
      partial: "comment_threads/thread",
      locals: { thread: thread, plan: plan }
    )
  end
end
