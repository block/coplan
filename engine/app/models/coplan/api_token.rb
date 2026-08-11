module CoPlan
  class ApiToken < ApplicationRecord
    HOLDER_TYPE = "local_agent"

    DEFAULT_SESSION_TTL = 12.hours
    MAX_SESSION_TTL = 7.days

    belongs_to :user, class_name: "CoPlan::User"
    belongs_to :parent, class_name: "CoPlan::ApiToken", optional: true
    has_many :children, class_name: "CoPlan::ApiToken", foreign_key: :parent_id, dependent: :nullify,
      inverse_of: :parent

    validates :name, presence: true
    validates :token_digest, presence: true, uniqueness: true

    scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
    scope :roots, -> { where(parent_id: nil) }

    def self.authenticate(raw_token)
      return nil if raw_token.blank?
      digest = Digest::SHA256.hexdigest(raw_token)
      token = active.find_by(token_digest: digest)
      return nil if token.nil? || token.parent_disabled?
      token.touch(:last_used_at)
      token
    end

    # Mints a short-lived child token for a single agent run. The child
    # inherits the principal (never escalates past its parent's user) and
    # cannot mint further children, so the tree stays one level deep and
    # revoking the root is enough to shut everything down.
    def mint_session_token!(name: nil, agent_name: nil, ttl: DEFAULT_SESSION_TTL)
      raise Minting::NotPermitted, "session tokens cannot mint further tokens" unless can_mint?

      ttl = [[ttl.to_i, 1.minute.to_i].max, MAX_SESSION_TTL.to_i].min
      self.class.create_with_raw_token(
        user_id: user_id,
        parent_id: id,
        name: name.presence || "#{self.name} session",
        agent_name: agent_name.presence || self.agent_name,
        expires_at: ttl.seconds.from_now
      )
    end

    def can_mint?
      parent_id.nil?
    end

    def session_token?
      parent_id.present?
    end

    # A child is only as alive as the token that minted it.
    def parent_disabled?
      parent_id.present? && !parent&.active?
    end

    def self.generate_token
      SecureRandom.hex(32)
    end

    def self.create_with_raw_token(**attributes)
      raw_token = generate_token
      api_token = create!(
        **attributes,
        token_digest: Digest::SHA256.hexdigest(raw_token),
        token_prefix: raw_token[0, 8]
      )
      [api_token, raw_token]
    end

    def revoked?
      revoked_at.present?
    end

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def active?
      !revoked? && !expired?
    end

    def revoke!
      transaction do
        update!(revoked_at: Time.current)
        children.where(revoked_at: nil).update_all(revoked_at: Time.current, updated_at: Time.current)
      end
    end

    module Minting
      class NotPermitted < StandardError; end
    end
  end
end
