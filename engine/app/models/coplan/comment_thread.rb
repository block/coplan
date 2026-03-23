module CoPlan
  class CommentThread < ApplicationRecord
    STATUSES = %w[pending todo resolved discarded].freeze
    OPEN_STATUSES = %w[pending todo].freeze
    CLOSED_STATUSES = %w[resolved discarded].freeze

    attr_accessor :anchor_occurrence

    belongs_to :plan
    belongs_to :plan_version
    belongs_to :created_by_user, class_name: "CoPlan::User"
    belongs_to :resolved_by_user, class_name: "CoPlan::User", optional: true
    belongs_to :out_of_date_since_version, class_name: "PlanVersion", optional: true
    belongs_to :addressed_in_plan_version, class_name: "PlanVersion", optional: true
    has_many :comments, dependent: :destroy

    validates :status, presence: true, inclusion: { in: STATUSES }

    before_create :resolve_anchor_position

    scope :open_threads, -> { where(status: OPEN_STATUSES) }
    scope :current, -> { where(out_of_date: false) }
    scope :active, -> { where(status: OPEN_STATUSES, out_of_date: false) }
    scope :archived, -> { where("status NOT IN (?) OR out_of_date = ?", OPEN_STATUSES, true) }

    # Transforms anchor positions through intervening version edits using OT.
    # Threads without positional data (anchor_start/anchor_end/anchor_revision)
    # are marked out-of-date unconditionally — all new threads resolve positions
    # on creation via resolve_anchor_position.
    def self.mark_out_of_date_for_new_version!(new_version)
      threads = where(out_of_date: false).where.not(plan_version_id: new_version.id)
      anchored_threads = threads.select(&:anchored?)

      # Pre-fetch all versions that any thread might need (from the oldest
      # anchor_revision to the new version) in a single query.
      min_anchor_rev = anchored_threads
        .filter_map { |t| t.anchor_revision if t.anchor_start.present? && t.anchor_end.present? && t.anchor_revision.present? }
        .min

      all_versions = if min_anchor_rev
        new_version.plan.plan_versions
          .where("revision > ? AND revision <= ?", min_anchor_rev, new_version.revision)
          .order(revision: :asc)
          .to_a
      else
        []
      end

      anchored_threads.each do |thread|
        unless thread.anchor_start.present? && thread.anchor_end.present? && thread.anchor_revision.present?
          thread.update_columns(out_of_date: true, out_of_date_since_version_id: new_version.id)
          next
        end

        intervening = all_versions.select { |v| v.revision > thread.anchor_revision && v.revision <= new_version.revision }

        begin
          new_range = Plans::TransformRange.transform_through_versions(
            [thread.anchor_start, thread.anchor_end],
            intervening
          )
          thread.update_columns(
            anchor_start: new_range[0],
            anchor_end: new_range[1],
            anchor_revision: new_version.revision
          )
        rescue Plans::TransformRange::Conflict
          thread.update_columns(
            out_of_date: true,
            out_of_date_since_version_id: new_version.id
          )
        end
      end
    end

    def anchored?
      anchor_text.present?
    end

    def line_specific?
      start_line.present?
    end

    def line_range_text
      return nil unless line_specific?
      start_line == end_line ? "Line #{start_line}" : "Lines #{start_line}–#{end_line}"
    end

    def anchor_preview(max_length: 80)
      return nil unless anchored?
      anchor_text.length > max_length ? "#{anchor_text[0...max_length]}…" : anchor_text
    end

    def resolve!(user)
      update!(status: "resolved", resolved_by_user: user)
    end

    def accept!(user)
      update!(status: "todo", resolved_by_user: user)
    end

    def discard!(user)
      update!(status: "discarded", resolved_by_user: user)
    end

    def open?
      OPEN_STATUSES.include?(status)
    end

    def anchor_valid?
      return true unless anchored?
      !out_of_date
    end

    # Returns the 0-based occurrence index of anchor_text in the raw markdown,
    # computed from anchor_start. The frontend uses this to find the correct
    # occurrence in the rendered DOM text instead of relying on context matching.
    def anchor_occurrence_index
      return nil unless anchored? && anchor_start.present?

      content = plan.current_content
      return nil unless content.present?

      count = 0
      pos = 0
      while (idx = content.index(anchor_text, pos))
        break if idx >= anchor_start
        count += 1
        pos = idx + 1
      end
      count
    end

    def anchor_context_with_highlight(chars: 100)
      return nil unless anchored? && anchor_start.present?

      content = plan.current_content
      return nil unless content.present?

      context_start = [anchor_start - chars, 0].max
      context_end = [anchor_end + chars, content.length].min

      before = content[context_start...anchor_start]
      anchor = content[anchor_start...anchor_end]
      after = content[anchor_end...context_end]

      "#{before}**#{anchor}**#{after}"
    end

    private

    def resolve_anchor_position
      return unless anchor_text.present?

      content = plan.current_content
      return unless content.present?

      occurrence = self.anchor_occurrence || 1
      return if occurrence < 1

      ranges = []
      start_pos = 0
      while (idx = content.index(anchor_text, start_pos))
        ranges << [idx, idx + anchor_text.length]
        start_pos = idx + anchor_text.length
      end

      if ranges.length >= occurrence
        range = ranges[occurrence - 1]
        self.anchor_start = range[0]
        self.anchor_end = range[1]
        self.anchor_revision = plan.current_revision
      end
    end
  end
end
