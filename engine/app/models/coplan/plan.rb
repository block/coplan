module CoPlan
  class Plan < ApplicationRecord
    STATUSES = %w[brainstorm considering developing live abandoned].freeze

    belongs_to :created_by_user, class_name: "CoPlan::User"
    belongs_to :current_plan_version, class_name: "PlanVersion", optional: true
    belongs_to :plan_type, optional: true
    has_many :plan_versions, -> { order(revision: :asc) }, dependent: :destroy
    has_many :plan_collaborators, dependent: :destroy
    has_many :collaborators, through: :plan_collaborators, source: :user
    has_many :comment_threads, dependent: :destroy
    has_many :edit_sessions, dependent: :destroy
    has_one :edit_lease, dependent: :destroy
    has_many :plan_tags, dependent: :destroy
    has_many :tags, through: :plan_tags, source: :tag
    has_many :plan_viewers, dependent: :destroy
    has_many :notifications, dependent: :destroy

    after_initialize { self.metadata ||= {} }

    validates :title, presence: true
    validates :status, presence: true, inclusion: { in: STATUSES }

    scope :with_tag, ->(name) { joins(:tags).where(coplan_tags: { name: name }) }

    def self.ransackable_attributes(auth_object = nil)
      %w[id title status plan_type_id created_by_user_id current_plan_version_id current_revision created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plan_type created_by_user]
    end

    def to_param
      id
    end

    def current_content
      current_plan_version&.content_markdown
    end

    def tag_names
      tags.pluck(:name)
    end

    def tag_names=(names)
      desired = Array(names).map(&:strip).reject(&:blank?).uniq
      self.tags = desired.map { |name| Tag.find_or_create_by!(name: name) }
    end
  end
end
