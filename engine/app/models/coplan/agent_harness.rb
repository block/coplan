module CoPlan
  class AgentHarness < ApplicationRecord
    STRING_LIMIT = 255
    BUILT_IN_ICONS = {
      "amp" => "coplan/agent-amp.svg",
      "claude-code" => "coplan/agent-claude.svg"
    }.freeze

    has_many :comments, dependent: :nullify

    validates :key, presence: true, uniqueness: true, length: { maximum: STRING_LIMIT }
    validates :display_name, presence: true, length: { maximum: STRING_LIMIT }
    validates :icon_url, length: { maximum: STRING_LIMIT },
      format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) }, allow_blank: true

    def self.resolve(identifier:)
      key = canonical_key(identifier)
      find_or_create_by!(key: key) do |harness|
        harness.display_name = default_display_name(key, identifier)
      end
    rescue ActiveRecord::RecordNotUnique
      find_by!(key: key)
    end

    def self.default_display_name(key, identifier)
      return "Amp" if key == "amp"
      return "Claude" if key == "claude-code"

      identifier.to_s.titleize.first(STRING_LIMIT).presence || "Agent"
    end

    def self.canonical_key(identifier)
      normalized = identifier.to_s.downcase
      return "amp" if normalized.match?(/\bamp\b/)
      return "claude-code" if normalized.include?("claude")

      normalized.parameterize.first(STRING_LIMIT).presence || "agent"
    end

    def built_in_icon
      BUILT_IN_ICONS.fetch(key, "coplan/agent-avatar.svg")
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id key display_name icon_url created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[comments]
    end
  end
end
