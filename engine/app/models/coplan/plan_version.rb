module CoPlan
  class PlanVersion < ApplicationRecord
    ACTOR_TYPES = %w[human local_agent cloud_persona system].freeze

    belongs_to :plan
    has_many :comment_threads, dependent: :nullify

    after_initialize { self.operations_json ||= [] }

    validates :revision, presence: true, uniqueness: { scope: :plan_id }
    validates :content_markdown, presence: true
    validates :content_sha256, presence: true
    validates :actor_type, presence: true, inclusion: { in: ACTOR_TYPES }

    before_validation :compute_sha256, if: -> { content_markdown.present? && content_sha256.blank? }

    private

    def compute_sha256
      self.content_sha256 = Digest::SHA256.hexdigest(content_markdown)
    end
  end
end
