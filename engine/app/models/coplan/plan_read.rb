module CoPlan
  # A read receipt: proof that a particular credential has actually pulled
  # a plan's content at a particular revision.
  #
  # Why this exists: `base_revision` is an assertion, not evidence. An agent
  # that gets a 409 telling it the plan is now at revision 7 can re-send its
  # unchanged body with `base_revision: 7` and wipe out whatever the human
  # wrote — the very accident Plans::HumanEditGuard is there to prevent. A
  # receipt can only be earned by fetching the content, so "have you seen
  # the human's edit?" becomes a question the server can answer.
  #
  # Keyed per credential, not per person: an agent that mints a fresh token
  # for each run starts with no receipts and must read before it writes,
  # which is step one of the documented workflow anyway.
  class PlanRead < ApplicationRecord
    READER_TYPES = %w[api_token user].freeze

    belongs_to :plan

    validates :reader_type, presence: true, inclusion: { in: READER_TYPES }
    validates :reader_id, presence: true
    validates :last_seen_revision, presence: true

    # Records that `reader` has seen `revision`. Monotonic: a later read of
    # an older revision (a version fetch, a cached response) never walks the
    # receipt backwards.
    #
    # The advance is a single UPDATE whose WHERE clause *is* the
    # monotonicity, rather than a load-compare-save. Two concurrent reads on
    # the same credential can otherwise both load the same row and the
    # slower one can save the older revision last — walking the receipt
    # backwards and leaving an agent fenced after it genuinely read the
    # human's edit.
    def self.record!(plan:, reader_type:, reader_id:, revision:)
      return false if reader_type.blank? || reader_id.blank? || revision.blank?

      revision = revision.to_i
      scope = where(plan_id: plan.id, reader_type: reader_type, reader_id: reader_id)
      now = Time.current

      advanced = scope.where(last_seen_revision: ...revision)
        .update_all(last_seen_revision: revision, last_seen_at: now, updated_at: now)
      return true if advanced.positive?
      # No rows advanced: either the receipt is already at or past this
      # revision, or there is no receipt yet.
      return true if scope.exists?

      create!(
        plan_id: plan.id, reader_type: reader_type, reader_id: reader_id,
        last_seen_revision: revision, last_seen_at: now
      )
      true
    rescue ActiveRecord::RecordNotUnique
      # Another request inserted the row first; go around again and take the
      # UPDATE path. Terminates: the row now exists.
      retry
    end

    # Highest revision this credential has seen. Zero means "never read it",
    # which is deliberately indistinguishable from "read it before anything
    # existed" — both mean the reader can't have seen a human's edit.
    def self.revision_for(plan:, reader_type:, reader_id:)
      return 0 if reader_type.blank? || reader_id.blank?

      where(plan_id: plan.id, reader_type: reader_type, reader_id: reader_id)
        .pick(:last_seen_revision) || 0
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id plan_id reader_type reader_id last_seen_revision last_seen_at created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plan]
    end
  end
end
