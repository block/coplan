FactoryBot.define do
  factory :edit_lease do
    plan
    organization
    holder_type { "local_agent" }
    holder_id { SecureRandom.uuid }
    lease_token_digest { Digest::SHA256.hexdigest(SecureRandom.hex(32)) }
    expires_at { 5.minutes.from_now }
    last_heartbeat_at { Time.current }
  end
end
