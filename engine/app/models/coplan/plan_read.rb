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
    def self.record!(plan:, reader_type:, reader_id:, revision:)
      return nil if reader_type.blank? || reader_id.blank? || revision.blank?

      record = find_or_initialize_by(plan_id: plan.id, reader_type: reader_type, reader_id: reader_id)
      return record if record.persisted? && record.last_seen_revision >= revision.to_i

      record.last_seen_revision = revision.to_i
      record.last_seen_at = Time.current
      record.save!
      record
    rescue ActiveRecord::RecordNotUnique
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
