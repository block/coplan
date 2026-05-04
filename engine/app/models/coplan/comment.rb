module CoPlan
  class Comment < ApplicationRecord
    AUTHOR_TYPES = %w[human local_agent cloud_persona system].freeze

    belongs_to :comment_thread

    validates :body_markdown, presence: true
    validates :author_type, presence: true, inclusion: { in: AUTHOR_TYPES }
    validates :agent_name, presence: { message: "is required for agent comments" }, if: -> { author_type == "local_agent" }
    validates :agent_name, length: { maximum: 20 }, allow_nil: true

    before_save :rewrite_plain_mentions, if: :body_markdown_changed?
    after_create_commit :notify_plan_author, if: :first_comment_in_thread?
    # Runs on save (not just create) so adding a mention via edit also
    # notifies. ProcessMentions uses find_or_create_by to dedupe.
    after_save_commit :process_mentions, if: :saved_change_to_body_markdown?

    def agent?
      agent_name.present? || author_type.in?(%w[local_agent cloud_persona])
    end

    # Resolves the comment author to a CoPlan::User instance, or nil for
    # author types that don't map to a user (cloud_persona, system).
    def author
      case author_type
      when "human"
        CoPlan::User.find_by(id: author_id)
      when "local_agent"
        CoPlan::User.joins(:api_tokens).where(coplan_api_tokens: { id: author_id }).first
      end
    end

    private

    def first_comment_in_thread?
      !comment_thread.comments.where("id < ?", id).exists?
    end

    def notify_plan_author
      CoPlan::NotificationJob.perform_later("comment_created", { comment_thread_id: comment_thread_id })
    end

    def process_mentions
      CoPlan::Comments::ProcessMentions.call(self)
    end

    def rewrite_plain_mentions
      self.body_markdown = CoPlan::Comments::RewriteMentions.call(body_markdown)
    end
  end
end
