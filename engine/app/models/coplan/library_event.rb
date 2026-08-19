module CoPlan
  # A first-class audit entry for a library's organization — plans filed,
  # moved, or removed; folders created, renamed, moved, described, or
  # deleted. The library-side counterpart to PlanEvent: PlanEvent answers
  # "what happened to this document?", LibraryEvent answers "who rearranged
  # this shelf, and was it a human or an agent?".
  #
  # plan_id / folder_id are soft references (no FK): audit rows outlive the
  # things they describe. Paths live in before_value/after_value and titles
  # in metadata, so the log stays readable after deletion.
  #
  # Records are append-only — never updated, never destroyed except through
  # the parent library's cascade.
  class LibraryEvent < ApplicationRecord
    # Mirrors PlanEvent::ACTOR_TYPES so both logs render uniformly.
    ACTOR_TYPES = %w[human local_agent cloud_persona system].freeze

    EVENT_TYPES = %w[
      plan_filed
      plan_moved
      plan_removed
      folder_created
      folder_renamed
      folder_moved
      folder_described
      folder_deleted
    ].freeze

    belongs_to :library, class_name: "CoPlan::Library", inverse_of: :library_events
    belongs_to :actor_user, class_name: "CoPlan::User", foreign_key: "actor_id", optional: true
    belongs_to :api_token, class_name: "CoPlan::ApiToken", optional: true

    after_initialize { self.metadata ||= {} }

    validates :actor_type, presence: true, inclusion: { in: ACTOR_TYPES }
    validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
    validates :agent_name, length: { maximum: ApiToken::AGENT_NAME_LIMIT }, allow_nil: true

    scope :recent_first, -> { order(created_at: :desc, id: :desc) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id library_id actor_id actor_type agent_name api_token_id event_type plan_id folder_id run_id before_value after_value created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[library actor_user api_token]
    end
  end
end
