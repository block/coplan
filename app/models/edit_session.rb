class EditSession < ApplicationRecord
  STATUSES = %w[open committed expired cancelled failed].freeze
  ACTOR_TYPES = %w[human local_agent cloud_persona].freeze
  LOCAL_AGENT_TTL = 10.minutes
  CLOUD_PERSONA_TTL = 30.minutes

  belongs_to :plan
  belongs_to :organization
  belongs_to :plan_version, optional: true

  after_initialize { self.operations_json ||= [] }
  after_create :enqueue_expiry_job

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :actor_type, presence: true, inclusion: { in: ACTOR_TYPES }
  validates :base_revision, presence: true
  validates :expires_at, presence: true

  scope :open_sessions, -> { where(status: "open") }
  scope :expired_pending, -> { where(status: "open").where("expires_at < ?", Time.current) }

  def open?
    status == "open"
  end

  def active?
    open? && (expires_at.nil? || expires_at > Time.current)
  end

  def committed?
    status == "committed"
  end

  def expired?
    open? && expires_at < Time.current
  end

  def has_operations?
    operations_json.present? && operations_json.any?
  end

  def add_operation(op)
    self.operations_json = operations_json + [op]
    save!
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[id status actor_type actor_id plan_id organization_id base_revision created_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[plan organization plan_version]
  end

  private

  def enqueue_expiry_job
    CommitExpiredSessionJob.set(wait_until: expires_at).perform_later(session_id: id)
  end
end
