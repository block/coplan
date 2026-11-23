module Coplan
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
      review.requested
      review.responded
      session.commit_failed
    ].freeze

    belongs_to :api_token, class_name: "Coplan::ApiToken"
    belongs_to :plan, class_name: "Coplan::Plan"

    validates :event_type, inclusion: { in: TYPES }

    scope :for_token, ->(token) { where(api_token_id: token.id) }
    scope :pending, -> { where(acked_at: nil) }
    scope :after, ->(cursor) { where("id > ?", cursor) }
    scope :oldest_first, -> { order(:id) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id api_token_id plan_id comment_thread_id comment_id event_type acked_at created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[api_token plan]
    end

    def self.as_api_json_batch(events)
      comment_ids = events.filter_map do |event|
        event.comment_id if event.payload.is_a?(Hash) && event.payload.key?("comment_body")
      end
      visible_ids = Comment.kept.where(id: comment_ids).pluck(:id).to_set
      events.map { |event| event.as_api_json(comment_visible: visible_ids.include?(event.comment_id)) }
    end

    def as_api_json(comment_visible: nil)
      {
        id: id,
        type: event_type,
        plan_id: plan_id,
        comment_thread_id: comment_thread_id,
        comment_id: comment_id,
        payload: public_payload(comment_visible: comment_visible),
        created_at: created_at
      }
    end

    private

    def public_payload(comment_visible:)
      return payload unless comment_id.present? && payload.is_a?(Hash) && payload.key?("comment_body")
      visible = comment_visible.nil? ? Comment.kept.exists?(id: comment_id) : comment_visible
      return payload if visible

      payload.merge("comment_body" => Comment::DELETED_BODY)
    end
  end
end
