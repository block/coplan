module CoPlan
  class Comment < ApplicationRecord
    AUTHOR_TYPES = %w[human local_agent cloud_persona system].freeze

    belongs_to :comment_thread

    validates :body_markdown, presence: true
    validates :author_type, presence: true, inclusion: { in: AUTHOR_TYPES }
    validates :agent_name, presence: { message: "is required for agent comments" }, if: -> { author_type == "local_agent" }
    validates :agent_name, length: { maximum: 20 }, allow_nil: true

    after_create_commit :notify_plan_author, if: :first_comment_in_thread?

    def agent?
      agent_name.present? || author_type.in?(%w[local_agent cloud_persona])
    end

    private

    def first_comment_in_thread?
      self == comment_thread.comments.order(:created_at).first
    end

    def notify_plan_author
      CoPlan::NotificationJob.perform_later("comment_created", { comment_thread_id: comment_thread_id })
    end
  end
end
