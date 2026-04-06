module CoPlan
  class Tag < ApplicationRecord
    has_many :plan_tags, dependent: :destroy
    has_many :plans, through: :plan_tags

    validates :name, presence: true, uniqueness: true

    def self.ransackable_attributes(auth_object = nil)
      %w[id name plans_count created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plan_tags plans]
    end
  end
end
