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

    after_save_commit :refresh_search_text!, if: :search_text_needs_refresh?

    # Sitewide search over a denormalized `search_text` column maintained by
    # `refresh_search_text!`. Uses MySQL FULLTEXT in BOOLEAN mode so we can
    # support prefix matches (`foo*`) and don't trip MySQL's 50%-of-rows
    # natural-language threshold on small datasets.
    #
    # Visibility: brainstorm plans are hidden from everyone except their
    # author — matches the `index` action's filter. `user` is required;
    # the controller enforces sign-in so we don't have to handle nil here.
    scope :search, ->(query, user:) {
      term = sanitize_fulltext_term(query)
      return none if term.blank?

      where.not(status: "brainstorm").or(where(created_by_user_id: user.id))
        .where("MATCH(search_text) AGAINST (? IN BOOLEAN MODE)", term)
        .order(Arel.sql("MATCH(search_text) AGAINST (#{connection.quote(term)} IN BOOLEAN MODE) DESC"))
    }

    def self.sanitize_fulltext_term(query)
      # FULLTEXT BOOLEAN-mode operators we strip so user input can't break the
      # query: + - > < ( ) ~ * " @ and stray backslashes. After stripping we
      # split on whitespace, drop empty tokens, and append `*` to each so
      # typing "foo bar" matches "foobar baz" mid-stream — important for the
      # search-as-you-type UX.
      cleaned = query.to_s.gsub(/[+\-><()~*"@\\]/, " ")
      tokens = cleaned.split(/\s+/).reject(&:blank?)
      tokens.map { |t| "#{t}*" }.join(" ")
    end

    # Recomputes the denormalized `search_text` column from the plan's title,
    # author name, tag names, and stripped current content. Called from the
    # after-commit hook above and from the backfill migration.
    def refresh_search_text!
      new_text = self.class.build_search_text(self)
      return if new_text == search_text
      update_columns(search_text: new_text)
    end

    # Builds the denormalized search text for a plan. Exposed as a class
    # method so the backfill migration can call it without instantiating
    # callbacks.
    #
    # Uses `map(&:name)` rather than `pluck(:name)` so callers that preload
    # `:tags` (e.g. the migration backfill) don't trigger an extra query per
    # plan.
    def self.build_search_text(plan)
      parts = []
      parts << plan.title.to_s
      parts << plan.created_by_user&.name.to_s
      parts << plan.tags.map(&:name).join(" ") if plan.persisted?
      content = plan.current_plan_version&.content_markdown
      if content.present?
        stripped, _ = Plans::MarkdownTextExtractor.call(content)
        parts << stripped
      end
      parts.reject(&:blank?).join(" ")
    end

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

    private

    # Refresh `search_text` when any of the inputs that feed into it have
    # changed at the Plan level. Tag and PlanVersion changes call
    # `refresh_search_text!` directly from their own callbacks.
    def search_text_needs_refresh?
      saved_change_to_title? || saved_change_to_current_plan_version_id? || saved_change_to_created_by_user_id?
    end
  end
end
