class Organization < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :plans, dependent: :destroy
  has_many :api_tokens, dependent: :destroy
  has_many :edit_leases, dependent: :destroy
  has_many :automated_plan_reviewers, dependent: :destroy

  after_initialize { self.allowed_email_domains ||= [] }
  after_create { AutomatedPlanReviewer.create_defaults_for(self) }

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "only allows lowercase letters, numbers, and hyphens" }

  def email_domain_allowed?(email)
    domain = email.to_s.split("@").last&.downcase
    return false if domain.blank?

    allowed_email_domains.any? { |d| d.downcase == domain }
  end
end
