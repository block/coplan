module CoPlan
  class User < ApplicationRecord
    has_many :api_tokens, dependent: :destroy
    has_many :plan_collaborators, dependent: :destroy

    validates :external_id, presence: true, uniqueness: true
    validates :name, presence: true

    after_initialize { self.metadata ||= {} }
  end
end
