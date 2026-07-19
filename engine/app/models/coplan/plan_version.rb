module CoPlan
  class PlanVersion < ApplicationRecord
    ACTOR_TYPES = %w[human local_agent cloud_persona system].freeze

    belongs_to :plan
    belongs_to :actor_user, class_name: "CoPlan::User", foreign_key: "actor_id", optional: true
    has_many :comment_threads, dependent: :nullify

    # has_attribute? guard: list pages load lean stubs (id + sha only) via
    # Plan#current_version_stub, which never select this column.
    after_initialize { self.operations_json ||= [] if has_attribute?(:operations_json) }

    validates :revision, presence: true, uniqueness: { scope: :plan_id }
    validates :content_markdown, presence: true
    validates :content_sha256, presence: true
    validates :actor_type, presence: true, inclusion: { in: ACTOR_TYPES }

    before_validation :compute_sha256, if: -> { content_markdown.present? && content_sha256.blank? }

    # Marker so a mixed history feed (PlanVersion + PlanEvent) can render each
    # item appropriately without introspecting class names.
    def history_kind
      :version
    end

    after_create_commit :extract_references
    after_create_commit :broadcast_history_update
    after_create_commit :enqueue_summary_regeneration

    private

    def extract_references
      CoPlan::References::ExtractFromContent.call(plan: plan, content: content_markdown)
      broadcast_references_update
    end

    def broadcast_history_update
      Broadcaster.prepend_to(
        plan,
        target: "plan-history-list",
        partial: "coplan/plans/version_item",
        locals: { version: self, plan: plan }
      )
      count = plan.plan_versions.count + plan.plan_events.count
      Broadcaster.replace_to(
        plan,
        target: "history-count",
        html: ApplicationController.helpers.content_tag(:span, count, class: "plan-tabs__count", id: "history-count")
      )
    end

    def broadcast_references_update
      references = plan.references.reload.order(reference_type: :asc, created_at: :desc)
      Broadcaster.replace_to(
        plan,
        target: "plan-references",
        partial: "coplan/plans/references",
        locals: { references: references, plan: plan }
      )
      Broadcaster.replace_to(
        plan,
        target: "references-count",
        html: ApplicationController.helpers.content_tag(:span, references.size, class: "plan-tabs__count", id: "references-count")
      )
    end

    def compute_sha256
      self.content_sha256 = Digest::SHA256.hexdigest(content_markdown)
    end

    # Fire SummarizePlanJob after every new version. The job is debounced
    # against `plan.summary_content_sha256`, so rapid back-to-back versions
    # collapse to a single AI call. The `wait` further reduces wasted calls
    # during a burst of edits (e.g. a session commit followed by another).
    def enqueue_summary_regeneration
      SummarizePlanJob.set(wait: 10.seconds).perform_later(plan_id: plan_id)
    end
  end
end
