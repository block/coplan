module CoPlan
  # A first-class log entry for metadata mutations on a plan — status changes,
  # title changes, tag adds/removes, reference adds/removes, plan_type changes.
  #
  # Lives alongside PlanVersion (which captures content snapshots) so the
  # history tab can present a unified, time-sorted view of "everything that
  # happened to this plan" without overloading PlanVersion (which has hard
  # requirements like content_markdown / content_sha256 that don't apply to
  # metadata-only changes).
  #
  # Records are append-only — never updated, never destroyed except through
  # the parent plan's cascade.
  class PlanEvent < ApplicationRecord
    # Mirrors PlanVersion::ACTOR_TYPES so history items from either source can
    # be rendered uniformly.
    ACTOR_TYPES = %w[human local_agent cloud_persona system].freeze

    EVENT_TYPES = %w[
      status_changed
      title_changed
      plan_type_changed
      tag_added
      tag_removed
      reference_added
      reference_removed
      comment_deleted
      moved_to_folder
    ].freeze

    belongs_to :plan
    belongs_to :actor_user, class_name: "CoPlan::User", foreign_key: "actor_id", optional: true

    after_initialize { self.metadata ||= {} }

    validates :actor_type, presence: true, inclusion: { in: ACTOR_TYPES }
    validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }

    scope :for_history, -> { order(created_at: :desc) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id plan_id actor_id actor_type event_type field before_value after_value created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[plan actor_user]
    end

    # Marker so history rendering can branch on the kind of item without
    # introspecting class names.
    def history_kind
      :event
    end

    after_create_commit :broadcast_history_update

    private

    # Prepend the new event into the open history tab and bump the count
    # badge so anyone watching the plan sees metadata changes appear live
    # alongside content versions.
    def broadcast_history_update
      Broadcaster.prepend_to(
        plan,
        target: "plan-history-list",
        partial: "coplan/plans/event_item",
        locals: { event: self, plan: plan }
      )
      count = plan.plan_versions.count + plan.plan_events.count
      Broadcaster.replace_to(
        plan,
        target: "history-count",
        html: ApplicationController.helpers.content_tag(:span, count, class: "plan-tabs__count", id: "history-count")
      )
    end
  end
end
