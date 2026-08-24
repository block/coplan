module CoPlan
  # Keeps an old URL working after the thing it named moved or was renamed.
  #
  # This table is a **cache, not the record**. Every rename is already
  # written to PlanEvent (`title_changed`) and LibraryEvent
  # (`folder_renamed`, `folder_moved`, `plan_moved`) with before/after
  # values, append-only. So these rows can be rebuilt from scratch, which
  # is what makes pruning safe: evicting one costs a slow resolve, never a
  # dead link.
  #
  # Two kinds:
  #
  # - `exact`  — one URL to one URL. A retitled plan.
  # - `prefix` — rewrites the head of a path, so a single row covers
  #              everything beneath a renamed folder or library handle.
  #              O(renames), not O(documents).
  #
  # Paths are library-handle-first with no leading slash, matching what
  # the resolver walks: "orders/liveorder/cart-roadmap".
  class UrlAlias < ApplicationRecord
    KINDS = %w[exact prefix].freeze

    validates :path, presence: true, length: { maximum: 512 },
      uniqueness: { scope: :kind, case_sensitive: false }
    validates :target_path, presence: true, length: { maximum: 512 }
    validates :kind, presence: true, inclusion: { in: KINDS }

    scope :exact, -> { where(kind: "exact") }
    scope :prefix, -> { where(kind: "prefix") }

    # Rewrites a stale path to its current form, or returns nil when
    # nothing here knows about it.
    #
    # Exact matches win over prefix ones, and among prefixes the longest
    # wins — so a rename of "orders/ebt/q3" beats an older rename of
    # "orders/ebt" for a path under both. Follows chained renames (a
    # folder renamed twice) up to MAX_HOPS, which also breaks any cycle
    # that bad data could introduce.
    MAX_HOPS = 5

    def self.rewrite(path)
      original = normalize(path)
      return nil if original.blank?

      current = original
      MAX_HOPS.times do
        row = match(current)
        break if row.nil?

        current = row.apply(current)
        row.record_hit!
      end

      current == original ? nil : current
    end

    def self.match(path)
      exact.find_by(path: path) || longest_prefix_match(path)
    end

    # Candidate prefixes are every ancestor path of the given path, so the
    # lookup is one IN query rather than a LIKE scan.
    #
    # The path itself counts as one of its own prefixes: renaming a folder
    # has to fix the link to the folder, not only the links to what's
    # inside it. Without it a renamed library handle was never matched at
    # all — a one-segment path has no ancestors.
    def self.longest_prefix_match(path)
      segments = path.split("/")
      candidates = (1..segments.length).map { |n| segments.first(n).join("/") }

      prefix.where(path: candidates).max_by { |row| row.path.length }
    end

    def self.normalize(path)
      path.to_s.strip.delete_prefix("/").delete_suffix("/").downcase
    end

    # Records the rename of `from` to `to`. Idempotent, and skips the
    # no-op case where a rename didn't actually change the URL (fixing
    # capitalization, or editing a word the slug rules strip anyway).
    def self.record!(from:, to:, kind: "exact")
      from = normalize(from)
      to = normalize(to)
      return nil if from.blank? || to.blank? || from == to

      row = find_or_initialize_by(path: from, kind: kind)
      row.target_path = to
      # A path that was itself a target now points somewhere new; resetting
      # the counter keeps eviction honest about *this* alias.
      row.resolve_count = 0 if row.persisted? && row.target_path_changed?
      row.save!
      row
    end

    def apply(path)
      return target_path if kind == "exact"

      target_path + path[self.path.length..].to_s
    end

    def record_hit!
      # Throttled: a hot alias would otherwise write on every request.
      # rubocop:disable Rails/SkipsModelValidations
      return if last_resolved_at.present? && last_resolved_at > 1.day.ago

      self.class.where(id: id).update_all(
        resolve_count: self.class.arel_table[:resolve_count] + 1,
        last_resolved_at: Time.current
      )
      # rubocop:enable Rails/SkipsModelValidations
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id path kind target_path resolve_count last_resolved_at created_at updated_at]
    end
  end
end
