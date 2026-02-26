class User < ApplicationRecord
  include CoPlan::UserModel

  belongs_to :organization

  validates :email, presence: true
  validates :email, uniqueness: { scope: :organization_id }
  validates :name, presence: true
  validates :org_role, presence: true, inclusion: { in: %w[member admin] }

  validate :email_domain_must_be_allowed

  def admin?
    org_role == "admin"
  end

  def can_admin_coplan?
    admin?
  end

  def email_domain
    email.to_s.split("@").last&.downcase
  end

  private

  def email_domain_must_be_allowed
    return if organization.blank? || email.blank?

    unless organization.email_domain_allowed?(email)
      errors.add(:email, "domain is not allowed for this organization")
    end
  end
end
