module CoPlan
  class Reference < ApplicationRecord
    SOURCES = %w[extracted explicit].freeze
    REFERENCE_TYPES = %w[plan repository pull_request document link].freeze

    belongs_to :plan
    belongs_to :target_plan, class_name: "CoPlan::Plan", optional: true

    validates :url, presence: true, uniqueness: { scope: :plan_id }, format: { with: /\Ahttps?:\/\//i, message: "must start with http:// or https://" }
    validates :key, uniqueness: { scope: :plan_id }, allow_nil: true,
      format: { with: /\A[a-z0-9][a-z0-9_-]*\z/, message: "must be lowercase alphanumeric with hyphens/underscores" }, length: { maximum: 64 }
    validates :reference_type, presence: true, inclusion: { in: REFERENCE_TYPES }
    validates :source, presence: true, inclusion: { in: SOURCES }

    scope :extracted, -> { where(source: "extracted") }
    scope :explicit, -> { where(source: "explicit") }

    def self.classify_url(url)
      case url
      when %r{\Ahttps?://github\.com/[^/]+/[^/]+/pull/\d+}
        "pull_request"
      when %r{\Ahttps?://github\.com/[^/]+/[^/]+/?(\z|#|\?|/tree/|/blob/|/commit/)}
        "repository"
      when %r{/plans/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}}
        "plan"
      when %r{\Ahttps?://docs\.google\.com/}, %r{\Ahttps?://drive\.google\.com/}
        "document"
      when %r{\Ahttps?://[^/]*notion\.(so|site)/}
        "document"
      when %r{\Ahttps?://[^/]*confluence[^/]*/}
        "document"
      else
        "link"
      end
    end

    def self.extract_target_plan_id(url)
      return nil if url.blank?
      match = url.match(%r{/plans/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})})
      match&.[](1)
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id plan_id key url title reference_type source target_plan_id created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plan target_plan]
    end
  end
end
