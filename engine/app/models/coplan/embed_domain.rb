module CoPlan
  # A host approved by an administrator for embedded content. Approval is
  # exact: approving example.com does not also approve its subdomains.
  class EmbedDomain < ApplicationRecord
    HOSTNAME = /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
    before_validation { self.hostname = hostname.to_s.strip.downcase }
    validates :hostname, presence: true, length: { maximum: 253 },
      format: { with: HOSTNAME, message: "must be an exact hostname, without a URL, port or wildcard" },
      uniqueness: { case_sensitive: false }

    def self.ransackable_attributes(_auth = nil)
      %w[id hostname created_at updated_at]
    end

    def self.ransackable_associations(_auth = nil)
      []
    end
  end
end
