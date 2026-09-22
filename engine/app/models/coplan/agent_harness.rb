module CoPlan
  class AgentHarness < ApplicationRecord
    STRING_LIMIT = 255
    BUILT_INS = {
      "amp" => { display_name: "Amp", icon: "coplan/agent-amp.svg", pattern: /\bamp\b/ },
      "claude-code" => { display_name: "Claude", icon: "coplan/agent-claude.svg", pattern: /\bclaude(?:\s+code)?\b/ },
      "codex" => { display_name: "Codex", icon: "coplan/agent-codex.svg", pattern: /\bcodex\b/ },
      "cursor" => { display_name: "Cursor", icon: "coplan/agent-cursor.svg", pattern: /\bcursor(?:\s+agent)?\b/ },
      "gemini-cli" => { display_name: "Gemini CLI", icon: "coplan/agent-gemini.png", pattern: /\bgemini(?:\s+cli)?\b/ },
      "goose" => { display_name: "Goose", icon: "coplan/agent-goose.svg", pattern: /\bgoose\b/ },
      "opencode" => { display_name: "OpenCode", icon: "coplan/agent-opencode.png", pattern: /\bopen[\s_-]?code\b/ }
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

    def self.install_built_ins!
      BUILT_INS.each do |key, attributes|
        find_or_create_by!(key: key) do |harness|
          harness.display_name = attributes.fetch(:display_name)
        end
      rescue ActiveRecord::RecordNotUnique
        find_by!(key: key)
      end
    end

    def self.default_display_name(key, identifier)
      built_in = BUILT_INS[key]
      return built_in.fetch(:display_name) if built_in

      identifier.to_s.titleize.first(STRING_LIMIT).presence || "Agent"
    end

    def self.canonical_key(identifier)
      normalized = identifier.to_s.downcase
      built_in = BUILT_INS.find { |_key, attributes| normalized.match?(attributes.fetch(:pattern)) }
      return built_in.first if built_in

      normalized.parameterize.first(STRING_LIMIT).presence || "agent"
    end

    def built_in_icon
      BUILT_INS.dig(key, :icon) || "coplan/agent-avatar.svg"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id key display_name icon_url created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[comments]
    end
  end
end
