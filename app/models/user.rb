class User < ApplicationRecord
  validates :email, presence: true, uniqueness: true
  validates :name, presence: true
  validates :role, presence: true, inclusion: { in: %w[member admin] }

  def admin?
    role == "admin"
  end

  def email_domain
    email.to_s.split("@").last&.downcase
  end
end
