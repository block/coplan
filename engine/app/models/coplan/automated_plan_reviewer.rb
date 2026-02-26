module CoPlan
  class AutomatedPlanReviewer < ApplicationRecord
    ACTOR_TYPE = "cloud_persona"
    AI_PROVIDERS = %w[openai anthropic].freeze

    DEFAULT_REVIEWERS = [
      { key: "security-reviewer", name: "Security Reviewer", prompt_file: "prompts/reviewers/security.md",
        trigger_statuses: [ "considering" ], ai_model: "gpt-4o" },
      { key: "scalability-reviewer", name: "Scalability Reviewer", prompt_file: "prompts/reviewers/scalability.md",
        trigger_statuses: [ "considering", "developing" ], ai_model: "gpt-4o" },
      { key: "routing-reviewer", name: "Routing Reviewer", prompt_file: "prompts/reviewers/routing.md",
        trigger_statuses: [], ai_model: "gpt-4o" }
    ].freeze

    after_initialize { self.trigger_statuses ||= [] }

    validates :key, presence: true,
      format: { with: /\A[a-z0-9-]+\z/, message: "only allows lowercase letters, numbers, and hyphens" }
    validates :key, uniqueness: true
    validates :name, presence: true
    validates :prompt_text, presence: true
    validates :ai_provider, presence: true, inclusion: { in: AI_PROVIDERS }
    validates :ai_model, presence: true
    validate :validate_trigger_statuses

    scope :enabled, -> { where(enabled: true) }

    def self.create_defaults
      DEFAULT_REVIEWERS.each do |template|
        find_or_create_by!(key: template[:key]) do |r|
          r.name = template[:name]
          r.prompt_text = File.read(CoPlan::Engine.root.join(template[:prompt_file]))
          r.trigger_statuses = template[:trigger_statuses]
          r.ai_model = template[:ai_model]
        end
      end
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id key name enabled ai_provider ai_model created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[]
    end

    def triggers_on_status?(status)
      trigger_statuses.include?(status.to_s)
    end

    private

    def validate_trigger_statuses
      return if trigger_statuses.blank?

      invalid = trigger_statuses - Plan::STATUSES
      if invalid.any?
        errors.add(:trigger_statuses, "contains invalid status: #{invalid.join(', ')}. Valid statuses are: #{Plan::STATUSES.join(', ')}")
      end
    end
  end
end
