class Organization < ApplicationRecord
  has_many :users, dependent: :destroy

  after_initialize { self.allowed_email_domains ||= [] }
  after_create { CoPlan::AutomatedPlanReviewer.create_defaults }

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "only allows lowercase letters, numbers, and hyphens" }

  def email_domain_allowed?(email)
    domain = email.to_s.split("@").last&.downcase
    return false if domain.blank?

    allowed_email_domains.any? { |d| d.downcase == domain }
  end
end
