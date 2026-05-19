module CoPlan
  class Plan < ApplicationRecord
    STATUSES = %w[brainstorm considering developing live abandoned].freeze

    belongs_to :created_by_user, class_name: "CoPlan::User"
    belongs_to :current_plan_version, class_name: "PlanVersion", optional: true
    belongs_to :plan_type, optional: true
    has_many :plan_versions, -> { order(revision: :asc) }, dependent: :destroy
    has_many :plan_events, dependent: :destroy
    has_many :plan_collaborators, dependent: :destroy
    has_many :collaborators, through: :plan_collaborators, source: :user
    has_many :comment_threads, dependent: :destroy
    has_many :edit_sessions, dependent: :destroy
    has_one :edit_lease, dependent: :destroy
    has_many :plan_tags, dependent: :destroy
    has_many :tags, through: :plan_tags, source: :tag
    has_many :plan_viewers, dependent: :destroy
    has_many :notifications, dependent: :destroy
    has_many :references, dependent: :destroy

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

    # Memoized stripped-markdown + position map for the current content.
    # Reused by multiple CommentThread#anchor_occurrence_index calls within
    # the same request to avoid re-parsing the full plan for each thread.
    def stripped_content
      @stripped_content ||= begin
        content = current_content
        content.present? ? Plans::MarkdownTextExtractor.call(content) : [+"", []]
      end
    end

    def tag_names
      tags.pluck(:name)
    end

    def tag_names=(names)
      desired = Array(names).map(&:strip).reject(&:blank?).uniq
      self.tags = desired.map { |name| Tag.find_or_create_by!(name: name) }
    end

    # Unified, time-sorted feed of everything that has happened to this plan:
    # both content versions (PlanVersion) and metadata events (PlanEvent).
    # Used by the history tab. Newest first.
    #
    # PlanVersions and PlanEvents both expose a `created_at` and a
    # `#history_kind` so the view can render each appropriately without
    # branching on class. Eager-loads actors for both to avoid N+1.
    def history_items
      versions = plan_versions.includes(:actor_user).order(revision: :desc).to_a
      events = plan_events.includes(:actor_user).order(created_at: :desc).to_a
      (versions + events).sort_by { |item| -item.created_at.to_f }
    end
  end
end
