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

    # `/plans/<uuid>` is self-identifying: nothing else on the web has that
    # shape, so a path alone is proof. A readable address isn't — now that
    # handles sit at the root, `/sam/liveorder/cart-roadmap` is shaped like
    # any other site's URL, and matching it on shape would type half the
    # links people paste as CoPlan documents.
    #
    # So the two forms are recognized by different means. The id form by
    # pattern, anywhere. The readable form only when we know the URL is ours
    # — either because the caller supplied our own host, or because the path
    # actually resolves to a document (see .extract_target_plan_id).
    PLAN_ID_PATH = %r{/plans/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})}
    READABLE_PLAN_PATH = %r{\A/([a-z0-9][a-z0-9-]*)/([^?#]+)}

    # `own_host` is the host CoPlan is being served from, when the caller
    # knows it. Views do (`request.host`); background work generally
    # doesn't, and gets the id form only.
    def self.classify_url(url, own_host: nil)
      case url
      when %r{\Ahttps?://github\.com/[^/]+/[^/]+/pull/\d+}
        "pull_request"
      when %r{\Ahttps?://github\.com/[^/]+/[^/]+/?(\z|#|\?|/tree/|/blob/|/commit/)}
        "repository"
      when PLAN_ID_PATH
        "plan"
      when %r{\Ahttps?://docs\.google\.com/}, %r{\Ahttps?://drive\.google\.com/}
        "document"
      when %r{\Ahttps?://[^/]*notion\.(so|site)/}
        "document"
      when %r{\Ahttps?://[^/]*confluence[^/]*/}
        "document"
      else
        own_document?(url, own_host) ? "plan" : "link"
      end
    end

    # Whether a URL is a readable address on our own host, deep enough to
    # name something inside a library rather than the library itself.
    def self.own_document?(url, own_host)
      return false if own_host.blank?

      uri = URI.parse(url.to_s)
      return false unless uri.host&.casecmp?(own_host)

      READABLE_PLAN_PATH.match?(uri.path.to_s)
    rescue URI::InvalidURIError
      false
    end

    # Type and target in one answer, because for a readable address they're
    # the same question: a path that resolves to one of our documents *is* a
    # plan reference, and the id it resolved to is what makes it one. A URL
    # that classified as a plain "link" therefore still gets a resolution
    # attempt, and is promoted if it lands.
    #
    # `excluding` is the citing plan's own id — a document linking to itself
    # is a link, not a reference to another document.
    #
    # Returns [ reference_type, target_plan_id ].
    def self.resolve_link(url, own_host: nil, excluding: nil)
      type = classify_url(url, own_host: own_host)
      return [ type, nil ] unless %w[plan link].include?(type)

      id = extract_target_plan_id(url)
      return [ type, nil ] if id.blank? || id == excluding || !Plan.exists?(id)

      [ "plan", id ]
    end

    # The id of the document a link points at, so the References section
    # can say which plan it is rather than just showing a URL.
    #
    # A readable path has to be resolved, since the id isn't in it. That
    # walk goes through the alias table too, so a link written before a
    # rename still finds the document it was always about — the same way
    # following the link would.
    #
    # Resolution doubles as the is-this-ours test, which is why this is
    # worth attempting on a URL that classified as a plain "link": if a
    # handle we know owns a path we can walk, the link is ours. Callers
    # promote the reference type when it comes back with an id.
    def self.extract_target_plan_id(url)
      return nil if url.blank?

      if (match = url.match(PLAN_ID_PATH))
        return match[1]
      end

      match = readable_match(url)
      return nil if match.nil?

      resolve_readable(match[1], match[2])
    end

    # Cheap gate before the segment walk: the first path segment has to be a
    # handle we actually have. Without it, every external link in a document
    # would cost a folder-tree query.
    def self.readable_match(url)
      uri = URI.parse(url.to_s)
      match = READABLE_PLAN_PATH.match(uri.path.to_s)
      return nil unless match && Library.find_by_handle(match[1])

      match
    rescue URI::InvalidURIError
      nil
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
