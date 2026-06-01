module CoPlan
  # A query a user typed into the sitewide search modal. Persisted so the
  # modal can show a "Recent searches" list when the input is empty.
  #
  # We only ever store one row per (user, query) pair — repeating the same
  # search bumps `created_at` on the existing row instead of growing the
  # table. Reads are capped at `RECENT_LIMIT`.
  class SearchQuery < ApplicationRecord
    RECENT_LIMIT = 10

    self.record_timestamps = false

    belongs_to :user, class_name: "CoPlan::User"

    validates :query, presence: true, length: { maximum: 255 }

    scope :recent_for, ->(user) {
      where(user: user).order(created_at: :desc).limit(RECENT_LIMIT)
    }

    def self.log!(user:, query:)
      return if user.blank?
      query = query.to_s.strip
      return if query.blank? || query.length > 255

      existing = where(user: user, query: query).first
      row = if existing
        existing.update_column(:created_at, Time.current)
        existing
      else
        create!(user: user, query: query, created_at: Time.current)
      end

      prune_for(user)
      row
    end

    # Keep at most `RECENT_LIMIT` rows per user so search-as-you-type doesn't
    # grow the table without bound. Cheap because `recent_for` is indexed.
    def self.prune_for(user)
      keep_ids = recent_for(user).pluck(:id)
      where(user: user).where.not(id: keep_ids).delete_all
    end
  end
end
