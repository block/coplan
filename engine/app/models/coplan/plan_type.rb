module CoPlan
  class PlanType < ApplicationRecord
    has_many :plans, dependent: :nullify

    after_initialize { self.default_tags ||= [] }
    after_initialize { self.metadata ||= {} }

    validates :name, presence: true, uniqueness: true

    def self.ransackable_attributes(auth_object = nil)
      %w[id name description created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plans]
    end
  end
end
