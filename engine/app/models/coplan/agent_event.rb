module CoPlan
  # One row per (event, subscribed agent token) — the durable inbox an agent
  # (or its bridge daemon) drains via GET /api/v1/agent/events. IDs are
  # UUIDv7, so lexicographic order is creation order and the id doubles as
  # the resume cursor.
  class AgentEvent < ApplicationRecord
    TYPES = %w[
      comment.created
      comment.replied
      thread.status_changed
      plan.content_changed
    ].freeze

    belongs_to :api_token, class_name: "CoPlan::ApiToken"
    belongs_to :plan, class_name: "CoPlan::Plan"

    validates :event_type, inclusion: { in: TYPES }

    scope :for_token, ->(token) { where(api_token_id: token.id) }
    scope :pending, -> { where(acked_at: nil) }
    scope :after, ->(cursor) { where("id > ?", cursor) }
    scope :oldest_first, -> { order(:id) }

    def as_api_json
      {
        id: id,
        type: event_type,
        plan_id: plan_id,
        comment_thread_id: comment_thread_id,
        comment_id: comment_id,
        payload: payload,
        created_at: created_at
      }
    end
  end
end
