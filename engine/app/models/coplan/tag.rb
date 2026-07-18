module CoPlan
  class Tag < ApplicationRecord
    has_many :plan_tags, dependent: :destroy
    has_many :plans, through: :plan_tags

    # Squish on the way in so "rails " and "rails" can't become two tags,
    # whichever write path created them.
    normalizes :name, with: ->(name) { name.squish }

    validates :name, presence: true, uniqueness: true

    # Tag names are baked into each plan's denormalized `search_text` (for
    # FULLTEXT search). When a tag is renamed via ActiveAdmin, every
    # associated plan still carries the old name in its index and won't
    # match the new one until something else touches the plan. Re-denormalize
    # every linked plan whenever `name` changes.
    after_update_commit :refresh_search_text_for_plans, if: :saved_change_to_name?

    def self.ransackable_attributes(auth_object = nil)
      %w[id name plans_count created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plan_tags plans]
    end

    private

    def refresh_search_text_for_plans
      plans.find_each(&:refresh_search_text!)
    end
  end
end
