module CoPlan
  class EditLease < ApplicationRecord
    HOLDER_TYPES = %w[human local_agent cloud_persona system].freeze
    LEASE_DURATION = 5.minutes

    class Conflict < StandardError; end
    class InvalidToken < StandardError; end

    belongs_to :plan

    validates :holder_type, presence: true, inclusion: { in: HOLDER_TYPES }
    validates :lease_token_digest, presence: true
    validates :expires_at, presence: true
    validates :last_heartbeat_at, presence: true

    def self.acquire!(plan:, holder_type:, holder_id:, lease_token:)
      raise InvalidToken, "Lease token must be a nonblank string" unless lease_token.is_a?(String) && lease_token.present?
      digest = Digest::SHA256.hexdigest(lease_token)

      ActiveRecord::Base.transaction do
        plan.lock! # Serializes acquisition even when no lease row exists yet.
        lease = EditLease.lock.find_by(plan_id: plan.id)
        if lease && lease.expires_at > Time.current && lease.lease_token_digest != digest
          raise Conflict, "Plan is currently being edited in another session"
        end
        lease ||= EditLease.new(plan_id: plan.id)
        lease.update!(
          holder_type: holder_type,
          holder_id: holder_id,
          lease_token_digest: digest,
          expires_at: LEASE_DURATION.from_now,
          last_heartbeat_at: Time.current
        )
        lease
      end
    end

    def renew!(lease_token:)
      plan.with_lock do
        reload
        raise Conflict, "Edit lock expired or changed. Reacquire it before saving." unless held_by?(lease_token: lease_token)
        update!(expires_at: LEASE_DURATION.from_now, last_heartbeat_at: Time.current)
      end
      self
    end

    def release!(lease_token:)
      plan.with_lock do
        reload
        raise Conflict, "Lease token mismatch" unless token_matches?(lease_token)
        destroy!
      end
    end

    # Call inside the plan row lock, including every PlanVersion creation.
    def self.enforce!(plan:, lease_token: nil)
      lease = find_by(plan_id: plan.id)
      return unless lease&.held?
      raise Conflict, "Plan is currently being edited in another session" unless lease.held_by?(lease_token: lease_token)
    end

    def held?
      expires_at > Time.current
    end

    def held_by?(lease_token:)
      token_matches?(lease_token) && held?
    end

    private

    def token_matches?(token)
      token.is_a?(String) && token.present? && lease_token_digest == Digest::SHA256.hexdigest(token)
    end
  end
end
