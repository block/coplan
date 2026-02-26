module CoPlan
  class EditLease < ApplicationRecord
    HOLDER_TYPES = %w[local_agent cloud_persona system].freeze
    LEASE_DURATION = 5.minutes

    class Conflict < StandardError; end

    belongs_to :plan

    validates :holder_type, presence: true, inclusion: { in: HOLDER_TYPES }
    validates :lease_token_digest, presence: true
    validates :expires_at, presence: true
    validates :last_heartbeat_at, presence: true

    def self.acquire!(plan:, holder_type:, holder_id:, lease_token:)
      digest = Digest::SHA256.hexdigest(lease_token)

      ActiveRecord::Base.transaction do
        lease = EditLease.lock.find_by(plan_id: plan.id)
        if lease && lease.expires_at > Time.current && lease.lease_token_digest != digest
          raise Conflict, "Plan is currently being edited by another agent"
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
      digest = Digest::SHA256.hexdigest(lease_token)
      raise Conflict, "Lease token mismatch" unless lease_token_digest == digest
      update!(expires_at: LEASE_DURATION.from_now, last_heartbeat_at: Time.current)
      self
    end

    def release!(lease_token:)
      digest = Digest::SHA256.hexdigest(lease_token)
      raise Conflict, "Lease token mismatch" unless lease_token_digest == digest
      destroy!
    end

    def held?
      expires_at > Time.current
    end

    def held_by?(lease_token:)
      digest = Digest::SHA256.hexdigest(lease_token)
      lease_token_digest == digest && held?
    end
  end
end
