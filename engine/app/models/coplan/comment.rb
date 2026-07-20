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
    after_create_commit :track_comment_created
    # Runs on save (not just create) so adding a mention via edit also
    # notifies. ProcessMentions uses find_or_create_by to dedupe.
    after_save_commit :process_mentions, if: -> { saved_change_to_body_markdown? && !deleted? }

    scope :kept, -> { where(deleted_at: nil) }

    def agent?
      agent_name.present? || author_type.in?(%w[local_agent cloud_persona])
    end

    def deleted?
      deleted_at.present?
    end

    def soft_delete!
      update!(deleted_at: Time.current)
    end

    # Resolves the comment author to a CoPlan::User instance, or nil for
    # author types that don't map to a user (cloud_persona, system).
    # For both human and local_agent comments, author_id is the user's id
    # (local_agent rows store the user behind the API token, not the token
    # id), so a single find_by resolves both — agent_name distinguishes
    # which agent posted on the user's behalf.
    def author
      return unless author_type.in?(%w[human local_agent])

      CoPlan::User.find_by(id: author_id)
    end

    private

    def first_comment_in_thread?
      # IDs are random UUIDs, not insertion-ordered, so we can't compare them
      # with `id < ?`. after_create_commit guarantees the row is persisted, so
      # a total count of 1 reliably means this comment opened the thread.
      # Memoized: both the notify and analytics callbacks ask.
      return @first_comment_in_thread if defined?(@first_comment_in_thread)
      @first_comment_in_thread = comment_thread.comments.count == 1
    end

    def notify_plan_author
      CoPlan::NotificationJob.perform_later("comment_created", { comment_thread_id: comment_thread_id })
    end

    def track_comment_created
      CoPlan::Analytics.track(
        "comment_created",
        user: author,
        plan_id: comment_thread.plan_id,
        comment_thread_id: comment_thread_id,
        comment_id: id,
        author_type: author_type,
        is_first_in_thread: first_comment_in_thread?,
        body_length: body_markdown.to_s.length
      )
    end

    def process_mentions
      CoPlan::Comments::ProcessMentions.call(self)
    end

    def rewrite_plain_mentions
      self.body_markdown = CoPlan::Comments::RewriteMentions.call(body_markdown)
    end
  end
end
