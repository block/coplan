module CoPlan
  class CommentThread < ApplicationRecord
    STATUSES = %w[open resolved].freeze
    OPEN_STATUSES = %w[open].freeze
    CLOSED_STATUSES = %w[resolved].freeze

    attr_accessor :anchor_occurrence

    belongs_to :plan
    belongs_to :plan_version
    belongs_to :created_by_user, class_name: "CoPlan::User"
    belongs_to :resolved_by_user, class_name: "CoPlan::User", optional: true
    belongs_to :out_of_date_since_version, class_name: "PlanVersion", optional: true
    belongs_to :addressed_in_plan_version, class_name: "PlanVersion", optional: true
    has_many :comments, dependent: :destroy
    has_many :notifications, dependent: :destroy

    validates :status, presence: true, inclusion: { in: STATUSES }

    # Resolution runs before validation so validation can see its result:
    # a thread whose anchor never resolved renders nowhere — no highlight,
    # no popover, no way to reach it from the page — so it is refused at
    # the door rather than created invisible. Create-only on both: a
    # resolved thread whose content later drifts is the out_of_date flow,
    # not a validity problem.
    before_validation :resolve_anchor_position, on: :create
    validate :anchor_must_resolve, on: :create

    # Closing a thread settles its inbox rows. Every path that resolves it
    # goes through an ordinary status write, so the sweep lives here rather
    # than in the controllers that trigger it.
    after_commit :mark_notifications_read_if_closed, on: :update

    scope :open_threads, -> { where(status: OPEN_STATUSES) }
    scope :current, -> { where(out_of_date: false) }
    scope :active, -> { where(status: OPEN_STATUSES, out_of_date: false) }
    scope :archived, -> { where("status NOT IN (?) OR out_of_date = ?", OPEN_STATUSES, true) }
    # Threads with at least one non-deleted comment. A thread whose only
    # comments have all been soft-deleted is effectively gone — hide it
    # from the doc view rather than leaving a dangling anchor + popover.
    scope :with_kept_comments, -> {
      where(id: CoPlan::Comment.kept.select(:comment_thread_id))
    }

    def empty?
      comments.kept.none?
    end

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
            [ thread.anchor_start, thread.anchor_end ],
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
      previous_status = status
      update!(status: "resolved", resolved_by_user: user)
      CoPlan::Analytics.track(
        "thread_resolved",
        user: user,
        plan_id: plan_id,
        comment_thread_id: id,
        previous_status: previous_status,
        comment_count: comments.count,
        anchored: anchored?
      )
    end

    def reopen!(user)
      update!(status: "open", resolved_by_user: nil)
    end

    def open?
      OPEN_STATUSES.include?(status)
    end

    def closed?
      CLOSED_STATUSES.include?(status)
    end

    def anchor_valid?
      return true unless anchored?
      !out_of_date
    end

    # Returns the 0-based occurrence index of anchor_text in the rendered
    # (stripped) content, computed from anchor_start. The frontend uses this
    # to find the correct occurrence in the rendered DOM text.
    def anchor_occurrence_index
      return nil unless anchored?

      content = plan.current_content
      return nil unless content.present?

      # When anchor_start is known, count occurrences before it.
      if anchor_start.present?
        # Folded the same way resolution folds it — the two have to agree on
        # what the text looks like or they disagree about which occurrence
        # this is, and the highlight lands on the wrong copy of the phrase.
        stripped, pos_map = self.class.fold_whitespace(*plan.stripped_content)
        # Map raw anchor_start to its position in the stripped string.
        # Use >= to find the closest valid position if anchor_start falls
        # on a stripped formatting character.
        stripped_start = pos_map.index { |raw_idx| raw_idx >= anchor_start }
        return nil if stripped_start.nil?

        ranges = find_all_occurrences(stripped, self.class.fold_anchor(anchor_text))
        return ranges.index { |s, _| s >= stripped_start } || 0
      end

      # Fallback: anchor_start was never resolved — default to 0 (first occurrence).
      0
    end

    def anchor_context_with_highlight(chars: 100)
      return nil unless anchored? && anchor_start.present?

      content = plan.current_content
      return nil unless content.present?

      context_start = [ anchor_start - chars, 0 ].max
      context_end = [ anchor_end + chars, content.length ].min

      before = content[context_start...anchor_start]
      anchor = content[anchor_start...anchor_end]
      after = content[anchor_end...context_end]

      "#{before}**#{anchor}**#{after}"
    end

    def self.strip_markdown(content)
      Plans::MarkdownTextExtractor.call(content)
    end

    # A browser hands back a selection with every run of whitespace collapsed
    # to a single space: a hard-wrapped paragraph is one flowing line on
    # screen, and the reader swept across it as one. The extractor keeps the
    # source's own newlines, so without this a selection that crosses a
    # wrapped line — reference or not — never resolves.
    def self.fold_anchor(text)
      text.gsub(/\s+/, " ")
    end

    # The same fold over the stripped text, carrying the position map. A run
    # collapses onto its first character, so ranges still land on real source
    # positions.
    def self.fold_whitespace(text, pos_map)
      folded = +""
      map = []
      in_run = false

      text.each_char.with_index do |char, i|
        if char.match?(/\s/)
          next if in_run
          in_run = true
          folded << " "
        else
          in_run = false
          folded << char
        end
        map << pos_map[i]
      end

      [ folded, map ]
    end

    private

    def mark_notifications_read_if_closed
      return unless saved_change_to_status? && closed?

      Notifications::MarkThreadRead.call(comment_thread: self)
    end

    def anchor_must_resolve
      return if anchor_text.blank? || anchor_start.present?

      errors.add(:anchor_text, "doesn't match the plan content — the comment would have nowhere to appear")
    end

    def resolve_anchor_position
      return unless anchor_text.present?

      content = plan.current_content
      return unless content.present?

      occurrence = self.anchor_occurrence || 1
      return if occurrence < 1

      # First, try an exact match against the raw markdown.
      ranges = find_all_occurrences(content, anchor_text)

      # If no exact match, the selected text may span markdown formatting
      # (e.g. DOM text "Hello me you" vs raw "Hello `me` you", or table
      # cell text without pipe delimiters). Parse the markdown AST to
      # extract plain text with source position mapping.
      if ranges.empty?
        stripped, pos_map = self.class.fold_whitespace(*self.class.strip_markdown(content))
        # Fold the anchor to match: tabs between table cells, and the newlines
        # a hard-wrapped paragraph carries, both reach us as plain spaces.
        normalized_anchor = self.class.fold_anchor(anchor_text)
        stripped_ranges = find_all_occurrences(stripped, normalized_anchor)

        # Mermaid labels line-break on literal <br/> tags, and the browser
        # reads the label back without them — "first<br/>fetching" renders
        # (and gets selected) as "firstfetching". Drop the tags from the
        # search text; the position map keeps pointing at the source.
        if stripped_ranges.empty?
          stripped, pos_map = remove_break_tags(stripped, pos_map)
          stripped_ranges = find_all_occurrences(stripped, normalized_anchor)
        end

        ranges = stripped_ranges.map do |s, e|
          raw_start = first_real_pos(pos_map, s, :forward)
          raw_end = first_real_pos(pos_map, e - 1, :backward)
          next nil unless raw_start && raw_end
          [ raw_start, raw_end + 1 ]
        end.compact
      end

      if ranges.length >= occurrence
        range = ranges[occurrence - 1]
        self.anchor_start = range[0]
        self.anchor_end = range[1]
        self.anchor_revision = plan.current_revision
      end
    end

    # Removes <br>/<br/> tags from stripped text, carrying the position
    # map along so matches still resolve to raw source positions.
    def remove_break_tags(text, pos_map)
      kept = +""
      map = []
      last = 0
      text.scan(/<br\s*\/?>/i) do
        m = Regexp.last_match
        kept << text[last...m.begin(0)]
        map.concat(pos_map[last...m.begin(0)])
        last = m.end(0)
      end
      kept << text[last..]
      map.concat(pos_map[last..])
      [ kept, map ]
    end

    # Finds the nearest non-sentinel (-1) position in the pos_map,
    # scanning forward or backward from the given index.
    def first_real_pos(pos_map, idx, direction)
      step = direction == :forward ? 1 : -1
      while idx >= 0 && idx < pos_map.length
        return pos_map[idx] if pos_map[idx] >= 0
        idx += step
      end
      nil
    end

    def find_all_occurrences(text, search)
      ranges = []
      start_pos = 0
      while (idx = text.index(search, start_pos))
        ranges << [ idx, idx + search.length ]
        start_pos = idx + search.length
      end
      ranges
    end
  end
end
