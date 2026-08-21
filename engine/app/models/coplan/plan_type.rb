module CoPlan
  class PlanType < ApplicationRecord
    GENERAL_NAME = "General"

    # How plans of this type render and behave. "document" is the classic
    # prose reading view; "presentation" renders the same markdown as a
    # slide deck (slides split on `---`). Behavior lives on the type row —
    # not on the type's name — so hosts can rename types freely.
    BEHAVIORS = %w[document presentation].freeze

    # Every plan must have a type, so a type with plans can't be deleted —
    # nullify would mint invalid (and, at the DB level, unstorable) plans.
    # Reassign the plans first, then delete.
    has_many :plans, dependent: :restrict_with_error

    after_initialize { self.default_tags ||= [] }
    after_initialize { self.metadata ||= {} }

    # Case-insensitive uniqueness so "General" and "general" can't coexist —
    # name lookups are case-insensitive (see find_by_name), so two types
    # differing only by case would be indistinguishable through the API.
    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validates :behavior, presence: true, inclusion: { in: BEHAVIORS }

    def presentation?
      behavior == "presentation"
    end

    # Case-insensitive, adapter-independent name lookup. MySQL's default
    # collations compare case-insensitively but PostgreSQL's don't, so a
    # plain find_by(name:) makes the API contract depend on the host's
    # database. All name-based plan-type resolution must go through here.
    def self.find_by_name(name)
      where("LOWER(name) = ?", name.to_s.downcase).first
    end

    # The catch-all type every untyped create falls back to (see
    # Plan#assign_default_plan_type). The RequirePlanTypeOnCoplanPlans
    # migration guarantees it exists in any migrated database, so the
    # create! branch only runs in fresh test databases.
    def self.general
      find_by_name(GENERAL_NAME) || create!(name: GENERAL_NAME, description: "General-purpose plan")
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      # Lost a race with a concurrent create — the row exists now.
      find_by_name(GENERAL_NAME)
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id name description icon behavior template_content created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plans]
    end
  end
end
