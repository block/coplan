class User < ApplicationRecord
  include CoPlan::UserModel

  validates :email, presence: true, uniqueness: true
  validates :name, presence: true
  validates :role, presence: true, inclusion: { in: %w[member admin] }

  def admin?
    role == "admin"
  end

  def can_admin_coplan?
    admin?
  end

  def email_domain
    email.to_s.split("@").last&.downcase
  end
end
