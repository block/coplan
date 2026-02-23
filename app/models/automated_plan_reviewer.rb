class AutomatedPlanReviewer < ApplicationRecord
  ACTOR_TYPE = "cloud_persona"

  belongs_to :organization, optional: true

  after_initialize { self.trigger_statuses ||= [] }

  validates :key, presence: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "only allows lowercase letters, numbers, and hyphens" }
  validates :key, uniqueness: { scope: :organization_id }
  validates :name, presence: true
  validates :prompt_path, presence: true
  validates :ai_provider, presence: true
  validates :ai_model, presence: true

  validate :prompt_file_exists

  scope :enabled, -> { where(enabled: true) }

  def self.ransackable_attributes(auth_object = nil)
    %w[id key name prompt_path enabled ai_provider ai_model organization_id created_at updated_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[organization]
  end

  def prompt_content
    File.read(Rails.root.join(prompt_path))
  end

  def triggers_on_status?(status)
    trigger_statuses.include?(status.to_s)
  end

  private

  def prompt_file_exists
    return if prompt_path.blank?
    unless File.exist?(Rails.root.join(prompt_path))
      errors.add(:prompt_path, "file does not exist: #{prompt_path}")
    end
  end
end
