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

    # A CoPlan document link in either form. `/l/<handle>/…` is what
    # people copy out of the address bar now; `/plans/<uuid>` is the old
    # form that still shows up in anything written before the switch.
    PLAN_ID_PATH = %r{/plans/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})}
    READABLE_PLAN_PATH = %r{/l/([^/?#]+)/([^?#]+)}

    def self.classify_url(url)
      case url
      when %r{\Ahttps?://github\.com/[^/]+/[^/]+/pull/\d+}
        "pull_request"
      when %r{\Ahttps?://github\.com/[^/]+/[^/]+/?(\z|#|\?|/tree/|/blob/|/commit/)}
        "repository"
      when PLAN_ID_PATH, READABLE_PLAN_PATH
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

    # The id of the document a link points at, so the References section
    # can say which plan it is rather than just showing a URL.
    #
    # A readable path has to be resolved, since the id isn't in it. That
    # walk goes through the alias table too, so a link written before a
    # rename still finds the document it was always about — the same way
    # following the link would.
    def self.extract_target_plan_id(url)
      return nil if url.blank?

      if (match = url.match(PLAN_ID_PATH))
        return match[1]
      end

      match = url.match(READABLE_PLAN_PATH)
      return nil if match.nil?

      resolve_readable(match[1], match[2])
    end

    def self.resolve_readable(handle, slug_path)
      result = Urls::Resolve.call(handle: handle, slug_path: slug_path)
      return result.plan&.id if result.redirect_to_path.blank?

      # A stale path the aliases recognized: walk the current one.
      current_handle, _, rest = result.redirect_to_path.partition("/")
      return nil if rest.blank?

      Urls::Resolve.call(handle: current_handle, slug_path: rest).plan&.id
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id plan_id key url title reference_type source target_plan_id created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[plan target_plan]
    end
  end
end
