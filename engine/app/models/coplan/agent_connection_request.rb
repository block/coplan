module CoPlan
  # A short-lived approval request, never a credential. Only digests of the
  # browser code and the separate, private redemption secret are persisted.
  class AgentConnectionRequest < ApplicationRecord
    STATUSES = %w[pending approved denied consumed].freeze
    LIFETIME = 10.minutes
    POLL_INTERVAL = 5.seconds

    belongs_to :user, optional: true

    validates :name, presence: true, length: { maximum: 100 }
    validates :status, inclusion: { in: STATUSES }
    validates :device_code_digest, :user_code_digest, :expires_at, presence: true
    validates :user, presence: true, unless: -> { status == "pending" }

    def self.issue!(name:)
      # Old requests carry no attribution; tokens retain their own history.
      where("expires_at < ?", 1.day.ago).limit(100).delete_all
      attempts = 0
      begin
        attempts += 1
        device_code = SecureRandom.hex(32)
        user_code = SecureRandom.hex(5).upcase.insert(5, "-")
        record = create!(name: name.to_s.strip, device_code_digest: digest(device_code),
          user_code_digest: digest(normalize_code(user_code)), expires_at: LIFETIME.from_now)
        [ record, device_code, user_code ]
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < 3
        raise
      end
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(value.to_s)
    end

    def self.normalize_code(value)
      value.to_s.delete("- ").upcase
    end

    def self.for_user_code(code)
      return if code.to_s.length > 20
      normalized = normalize_code(code)
      return unless normalized.match?(/\A[0-9A-F]{10}\z/)
      find_by(user_code_digest: digest(normalized))
    end

    def expired?
      expires_at <= Time.current
    end

    def pending?
      status == "pending" && !expired?
    end

    def decide!(user:, approve:)
      with_lock do
        return false unless pending?
        update!(user: user, status: approve ? "approved" : "denied")
      end
      true
    end

    # Locking makes approval/denial and simultaneous polls linear: exactly
    # one redemption can create a durable token, and a GET never creates one.
    def redeem!
      with_lock do
        return { error: "expired_token" } if expired?
        return { error: "access_denied" } if status == "denied"
        return { error: "invalid_grant" } if status == "consumed"
        if last_polled_at && last_polled_at > POLL_INTERVAL.ago
          return { error: "slow_down" }
        end
        update!(last_polled_at: Time.current)
        return { error: "authorization_pending" } if status == "pending"

        token, raw = ApiToken.create_with_raw_token(user: user, name: name)
        update!(status: "consumed")
        { token: raw, token_type: "Bearer", id: token.id, name: token.name }
      end
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id name status user_id expires_at created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user]
    end
  end
end
