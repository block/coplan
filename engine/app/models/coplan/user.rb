module CoPlan
  class User < ApplicationRecord
    has_many :api_tokens, dependent: :destroy
    has_many :plan_collaborators, dependent: :destroy
    has_many :notifications, dependent: :destroy

    validates :external_id, presence: true, uniqueness: true
    validates :name, presence: true
    validates :email, uniqueness: true, allow_nil: true

    after_initialize { self.metadata ||= {} }

    def self.ransackable_attributes(auth_object = nil)
      %w[id external_id name email admin created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[api_tokens plan_collaborators]
    end
  end
end
