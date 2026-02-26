module CoPlan
  class ApiToken < ApplicationRecord
    HOLDER_TYPE = "local_agent"

    belongs_to :user, class_name: CoPlan.user_class_name

    validates :name, presence: true
    validates :token_digest, presence: true, uniqueness: true

    scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

    def self.authenticate(raw_token)
      return nil if raw_token.blank?
      digest = Digest::SHA256.hexdigest(raw_token)
      token = active.find_by(token_digest: digest)
      token&.touch(:last_used_at)
      token
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
      update!(revoked_at: Time.current)
    end
  end
end
