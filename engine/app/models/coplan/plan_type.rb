module CoPlan
  class PlanType < ApplicationRecord
    has_many :plans, dependent: :nullify

    after_initialize { self.default_tags ||= [] }
    after_initialize { self.metadata ||= {} }

    # Case-insensitive uniqueness so "General" and "general" can't coexist —
    # name lookups are case-insensitive (see find_by_name), so two types
    # differing only by case would be indistinguishable through the API.
    validates :name, presence: true, uniqueness: { case_sensitive: false }

    # Case-insensitive, adapter-independent name lookup. MySQL's default
    # collations compare case-insensitively but PostgreSQL's don't, so a
    # plain find_by(name:) makes the API contract depend on the host's
    # database. All name-based plan-type resolution must go through here.
    def self.find_by_name(name)
      where("LOWER(name) = ?", name.to_s.downcase).first
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id name description icon template_content created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plans]
    end
  end
end
