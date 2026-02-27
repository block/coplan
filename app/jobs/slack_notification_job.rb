class SlackNotificationJob < ApplicationJob
  queue_as :default

  retry_on SlackClient::Error, wait: :polynomially_longer, attempts: 5
  discard_on SlackClient::PermanentError

  def perform(comment_thread_id:)
    return unless SlackClient.configured?

    thread = CoPlan::CommentThread.find(comment_thread_id)
    plan = thread.plan
    coplan_author = plan.created_by_user
    first_comment = thread.comments.order(:created_at, :id).first

    return unless first_comment
    return if first_comment.author_type == "human" && first_comment.author_id == coplan_author.id

    host_user = User.find_by(id: coplan_author.external_id)
    return unless host_user

    text = compose_message(thread, plan)
    SlackClient.send_dm(email: host_user.email, text: text)
  end

  private

  def compose_message(thread, plan)
    comment_body = first_comment_body(thread).truncate(300)
    plan_url = CoPlan::Engine.routes.url_helpers.plan_url(plan, **default_url_options)

    lines = ["New comment on *#{plan.title}*:"]
    if thread.anchor_text.present?
      lines << "> _#{thread.anchor_text.truncate(120)}_"
    end
    lines << "> #{comment_body}"
    lines << plan_url
    lines.join("\n")
  end

  def first_comment_body(thread)
    thread.comments.order(:created_at, :id).first&.body_markdown || ""
  end

  def default_url_options
    Rails.application.config.action_mailer.default_url_options || { host: "localhost", port: 3000 }
  end
end
