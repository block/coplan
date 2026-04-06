module CoPlan
  class PlanTag < ApplicationRecord
    belongs_to :plan
    belongs_to :tag, counter_cache: :plans_count

    validates :tag_id, uniqueness: { scope: :plan_id }

    def self.ransackable_attributes(auth_object = nil)
      %w[id plan_id tag_id created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plan tag]
    end
  end
end
