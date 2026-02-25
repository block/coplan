class SlackNotificationJob < ApplicationJob
  queue_as :default

  retry_on SlackClient::Error, wait: :polynomially_longer, attempts: 5
  discard_on SlackClient::PermanentError

  def perform(comment_thread_id:)
    return unless SlackClient.configured?

    thread = CommentThread.find(comment_thread_id)
    plan = thread.plan
    plan_author = plan.created_by_user
    commenter = thread.created_by_user

    return if commenter == plan_author

    text = compose_message(thread, plan)
    SlackClient.send_dm(email: plan_author.email, text: text)
  end

  private

  def compose_message(thread, plan)
    comment_body = first_comment_body(thread).truncate(300)
    plan_url = Rails.application.routes.url_helpers.plan_url(plan, host: default_host)

    lines = ["New comment on *#{plan.title}*:"]
    if thread.anchor_text.present?
      lines << "> _#{thread.anchor_text.truncate(120)}_"
    end
    lines << "> #{comment_body}"
    lines << plan_url
    lines.join("\n")
  end

  def first_comment_body(thread)
    thread.comments.order(:created_at).first&.body_markdown || ""
  end

  def default_host
    Rails.application.config.action_mailer.default_url_options&.dig(:host) || "localhost:3000"
  end
end
