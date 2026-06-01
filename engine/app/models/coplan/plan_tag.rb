module CoPlan
  class PlanTag < ApplicationRecord
    belongs_to :plan
    belongs_to :tag, counter_cache: :plans_count

    validates :tag_id, uniqueness: { scope: :plan_id }

    # Plan-level after_save_commit doesn't fire when tags change (the Plan row
    # itself isn't dirty), so re-denormalize the parent's `search_text` here.
    after_commit :refresh_plan_search_text, on: [:create, :destroy]

    def self.ransackable_attributes(auth_object = nil)
      %w[id plan_id tag_id created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plan tag]
    end

    private

    def refresh_plan_search_text
      # When a Plan is destroyed, ActiveRecord cascades to PlanTag (via
      # `dependent: :destroy`) and fires this hook. Skip the refresh in that
      # case — the parent row is gone and `update_columns` would raise.
      return if plan.nil? || plan.destroyed?
      plan.refresh_search_text!
    end
  end
end
