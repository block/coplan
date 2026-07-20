require "uri"

module CoPlan
  class LinkPreviews
    # CoPlan uses time-ordered UUIDv7 IDs, while imported installations may
    # contain older UUID versions. Validate the UUID shape, not one version.
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    DESCRIPTION_LENGTH = 240

    class << self
      def resolve(url:, base_url:)
        supplied = parse_url(url, enforce_https: true)
        base = parse_url(base_url, enforce_https: true)
        return unless supplied && base && safe_origin?(supplied, base)

        plan_id = plan_id_from(supplied.path, base.path)
        return unless plan_id

        plan = Plan.includes(:created_by_user, :plan_type, :current_plan_version).find_by(id: plan_id)
        for_plan(plan, base_url: base_url) if plan
      rescue URI::InvalidURIError
        nil
      end

      def for_plan(plan, base_url:)
        # This builder is also used by the server-rendered OG view, where
        # request specs and local reverse proxies may expose an HTTP origin.
        # Resolver inputs remain subject to the strict transport checks.
        base = parse_url(base_url, enforce_https: false)
        raise ArgumentError, "invalid base_url" unless base

        canonical = base.dup
        canonical.path = join_path(base.path, "plans/#{plan.id}")
        canonical.query = canonical.fragment = nil
        description = plan.summary.presence || plain_content(plan)

        LinkPreview.new(
          kind: "plan",
          external_id: plan.id,
          canonical_url: canonical.to_s,
          title: plan.title,
          description: truncate(description),
          # Published is the unmarked normal state; only Private/Archived get
          # a flag (and never the word "Draft" — matches the in-app language).
          context: [ plan_state_flag(plan), plan.plan_type&.name, "by #{plan.created_by_user.name}" ].compact.join(" · "),
          image_url: https_url(plan.metadata&.dig("image_url")),
          cache_key: [
            "plan", plan.id, plan.updated_at.to_f, plan.summary_generated_at&.to_f,
            plan.current_plan_version&.content_sha256 || plan.current_revision
          ].compact.join(":")
        )
      end

      private

      def plan_state_flag(plan)
        return "Archived" if plan.archived?
        return "Private" if plan.draft?
        nil
      end

      def parse_url(value, enforce_https:)
        uri = URI.parse(value.to_s)
        return unless %w[http https].include?(uri.scheme) && uri.host.present?
        return if uri.user || uri.password
        return if enforce_https && uri.scheme != "https" && !%w[localhost 127.0.0.1 ::1].include?(uri.host)
        uri
      end

      def safe_origin?(url, base)
        url.scheme == base.scheme && url.host.casecmp?(base.host) && url.port == base.port
      end

      def https_url(value)
        uri = parse_url(value, enforce_https: true)
        uri.to_s if uri&.scheme == "https"
      rescue URI::InvalidURIError
        nil
      end

      def plan_id_from(path, mount_path)
        mount = mount_path.to_s.sub(%r{/+\z}, "")
        relative = mount.empty? ? path : path.delete_prefix(mount)
        return if !mount.empty? && relative == path
        return unless relative.start_with?("/")

        match = relative.match(%r{\A/plans/([^/]+)(?:/history|/versions/([^/]+)(?:/diff)?)?/?\z})
        return unless match && UUID.match?(match[1])
        return if match[2] && !UUID.match?(match[2])
        match[1]
      end

      def join_path(base, suffix)
        "#{base.to_s.sub(%r{/+\z}, "")}/#{suffix}"
      end

      def plain_content(plan)
        content = plan.current_content
        content.present? ? Plans::MarkdownTextExtractor.call(content).first.squish : nil
      end

      def truncate(value)
        text = value.to_s.squish
        return if text.blank?
        return text if text.length <= DESCRIPTION_LENGTH
        "#{text.first(DESCRIPTION_LENGTH - 1).rstrip}…"
      end
    end
  end
end
