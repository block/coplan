class Comment < ApplicationRecord
  AUTHOR_TYPES = %w[human local_agent cloud_persona system].freeze

  belongs_to :comment_thread
  belongs_to :organization

  validates :body_markdown, presence: true
  validates :author_type, presence: true, inclusion: { in: AUTHOR_TYPES }
  validates :agent_name, presence: { message: "is required for agent comments" }, if: -> { author_type == "local_agent" }
  validates :agent_name, length: { maximum: 20 }, allow_nil: true
end
