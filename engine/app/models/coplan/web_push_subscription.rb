require "digest"

module CoPlan
  class WebPushSubscription < ApplicationRecord
    belongs_to :user, class_name: "CoPlan::User"

    validates :endpoint, presence: true
    validates :p256dh_key, presence: true
    validates :auth_key, presence: true
    validates :endpoint_digest, presence: true, uniqueness: true

    before_validation :compute_endpoint_digest, if: :endpoint_changed?

    # Hash an endpoint into the form stored as endpoint_digest. Centralized
    # so callers don't repeat the algorithm.
    def self.digest_for(endpoint)
      Digest::SHA256.hexdigest(endpoint.to_s)
    end

    # Idempotent upsert from a browser PushSubscription payload. The same
    # browser+device subscribing twice should overwrite (not duplicate) so
    # we key on the endpoint digest. Concurrent inserts are tolerated by
    # retrying the lookup after a unique-constraint collision.
    def self.upsert_for(user:, endpoint:, p256dh_key:, auth_key:, user_agent: nil)
      digest = digest_for(endpoint)
      attrs = {
        user: user,
        endpoint: endpoint,
        p256dh_key: p256dh_key,
        auth_key: auth_key,
        user_agent: user_agent,
        last_seen_at: Time.current
      }

      record = find_or_initialize_by(endpoint_digest: digest)
      record.assign_attributes(attrs)
      begin
        record.save!
      rescue ActiveRecord::RecordNotUnique
        record = find_by!(endpoint_digest: digest)
        record.update!(attrs)
      end
      record
    end

    def record_delivery!
      # Atomic increment so concurrent deliveries can't lose updates.
      increment!(:notifications_delivered_count, touch: :last_delivered_at)
    end

    # Best-effort friendly label like "Chrome on macOS" derived from the raw
    # User-Agent. Falls back to the raw UA, then "Unknown browser".
    def device_label
      ua = user_agent.to_s
      return "Unknown browser" if ua.blank?

      browser = case ua
                when /Edg\//                              then "Edge"
                when /OPR\//                              then "Opera"
                when /Firefox\//                          then "Firefox"
                when /Chrome\//                           then "Chrome"
                when /Safari\//                           then "Safari"
                end

      os = case ua
           when /iPhone OS|iOS/                           then "iOS"
           when /iPad/                                    then "iPadOS"
           when /Android/                                 then "Android"
           when /Mac OS X|Macintosh/                      then "macOS"
           when /Windows NT/                              then "Windows"
           when /Linux/                                   then "Linux"
           end

      return [browser, os].compact.join(" on ").presence || ua.truncate(80)
    end

    private

    def compute_endpoint_digest
      self.endpoint_digest = self.class.digest_for(endpoint) if endpoint.present?
    end
  end
end
