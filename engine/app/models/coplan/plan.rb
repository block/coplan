module CoPlan
  class Plan < ApplicationRecord
    VISIBILITIES = %w[draft published].freeze

    # Legacy API compatibility: the pre-2026-07 five-state `status` field.
    # Accepted on writes and emitted on reads for a deprecation window; the
    # canonical model is `visibility` + `archived_at`.
    LEGACY_STATUSES = %w[brainstorm considering developing live abandoned].freeze

    # Server-side limits for file attachments. Content types are an allowlist:
    # anything renderable-but-scriptable (html, svg, js) is deliberately
    # excluded so an attachment can never execute in a viewer's browser.
    ATTACHMENT_MAX_BYTES = 25.megabytes
    ATTACHMENT_CONTENT_TYPES = %w[
      image/png image/jpeg image/gif image/webp
      application/pdf
      text/plain text/markdown text/csv
      application/json
      application/zip
    ].freeze

    belongs_to :created_by_user, class_name: "CoPlan::User"
    belongs_to :current_plan_version, class_name: "PlanVersion", optional: true
    belongs_to :plan_type, optional: true
    belongs_to :folder, optional: true, inverse_of: :plans
    has_many :plan_versions, -> { order(revision: :asc) }, dependent: :destroy
    has_many :plan_events, dependent: :destroy
    has_many :plan_collaborators, dependent: :destroy
    has_many :collaborators, through: :plan_collaborators, source: :user
    has_many :comment_threads, dependent: :destroy
    has_many :comments, through: :comment_threads
    has_many :edit_sessions, dependent: :destroy
    has_one :edit_lease, dependent: :destroy
    has_many :plan_tags, dependent: :destroy
    has_many :tags, through: :plan_tags, source: :tag
    has_many :plan_viewers, dependent: :destroy
    has_many :notifications, dependent: :destroy
    has_many :references, dependent: :destroy
    has_many_attached :attachments

    after_initialize { self.metadata ||= {} }

    validates :title, presence: true
    validates :visibility, presence: true, inclusion: { in: VISIBILITIES }
    validate :attachments_within_limits

    scope :with_tag, ->(name) { joins(:tags).where(coplan_tags: { name: name }) }

    # Plans `user` is allowed to see: everything published plus the user's
    # own drafts. Drafts are private — any list, count, feed, search result,
    # or folder content shown to a user must go through this scope (or
    # PlanPolicy#show?, which mirrors it) so private draft existence never
    # leaks. This is THE visibility predicate: never test `visibility`
    # inline elsewhere.
    scope :visible_to, ->(user) {
      where(visibility: "published").or(where(created_by_user_id: user.id))
    }

    # Archived plans are hidden from every default surface; callers opt in
    # with `.archived` or by dropping the `.active` scope explicitly.
    scope :active, -> { where(archived_at: nil) }
    scope :archived, -> { where.not(archived_at: nil) }

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

      # Archived plans stay out of search — they remain reachable by direct
      # URL and via explicit archived filters, but never resurface on their
      # own.
      visible_to(user).active
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
      %w[id title visibility archived_at plan_type_id folder_id created_by_user_id current_plan_version_id current_revision created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plan_type created_by_user]
    end

    def to_param
      id
    end

    def draft?
      visibility == "draft"
    end

    def published?
      visibility == "published"
    end

    def archived?
      archived_at.present?
    end

    # Legacy API compatibility (see LEGACY_STATUSES). Emits the closest
    # five-state equivalent of the current visibility/archival state.
    def legacy_status
      return "brainstorm" if draft?
      return "abandoned" if archived?
      "considering"
    end

    # Maps a legacy five-state status write onto the canonical fields.
    # Returns the attributes to assign; raises nothing — validation of the
    # mapped values happens on save.
    def self.attributes_for_legacy_status(status)
      case status.to_s
      when "brainstorm" then { visibility: "draft", archived_at: nil }
      # Archiving must never implicitly publish: a draft archived via the
      # legacy API stays a (archived) draft rather than leaking.
      when "abandoned" then { archived_at: Time.current }
      when *LEGACY_STATUSES then { visibility: "published", archived_at: nil }
      else {}
      end
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
        content.present? ? Plans::MarkdownTextExtractor.call(content) : [ +"", [] ]
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

    # Backstop validation for attachment size/type. The primary check lives in
    # Plans::AddAttachment (which can reject before a blob is even created),
    # but this guarantees no code path can persist an oversized or disallowed
    # attachment — `attachments.attach` on a persisted record goes through
    # `save`, so a failure here aborts the attach. Only newly-built attachment
    # records in the pending change are validated: `attach` re-assigns
    # existing blobs alongside the new one, and re-validating already
    # persisted attachments would let one legacy attachment (attached under
    # older, looser rules) block every future upload on the plan.
    def attachments_within_limits
      change = attachment_changes["attachments"]
      return unless change.respond_to?(:attachments)

      change.attachments.each do |attachment|
        next if attachment.persisted?
        blob = attachment.blob
        next unless blob

        if blob.byte_size.to_i > ATTACHMENT_MAX_BYTES
          errors.add(:attachments, "#{blob.filename} is too large (maximum is #{ATTACHMENT_MAX_BYTES / 1.megabyte} MB)")
        end
        unless ATTACHMENT_CONTENT_TYPES.include?(blob.content_type)
          errors.add(:attachments, "#{blob.filename} has a disallowed content type (#{blob.content_type.presence || "unknown"})")
        end
      end
    end

    # Refresh `search_text` when any of the inputs that feed into it have
    # changed at the Plan level. Tag and PlanVersion changes call
    # `refresh_search_text!` directly from their own callbacks.
    def search_text_needs_refresh?
      saved_change_to_title? || saved_change_to_current_plan_version_id? || saved_change_to_created_by_user_id?
    end
  end
end
