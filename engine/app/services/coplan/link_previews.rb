require "cgi"
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

        plan = plan_from_legacy_path(supplied.path, base.path) ||
               plan_from_browsable_path(supplied.path, base.path)
        return unless plan

        for_plan(plan, base_url: base_url)
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
        # The browsable URL is canonical — /<handle>/<slug-path> — falling
        # back to the legacy /plans/<id> path only when url_path is nil
        # (a plan with no library or slug, which shouldn't happen in
        # practice since both are NOT NULL after the backfill migration).
        # Percent-encode each segment so Unicode slugs (Japanese, Arabic,
        # accented Latin) don't raise URI::InvalidComponentError.
        path_suffix = plan.url_path || "plans/#{plan.id}"
        canonical.path = join_path(base.path, encode_path_segments(path_suffix))
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
          author_name: plan.created_by_user.name,
          author_avatar_url: https_url(plan.created_by_user.avatar_url),
          cache_key: [
            "plan", plan.id, plan.updated_at.to_f, plan.summary_generated_at&.to_f,
            plan.created_by_user.updated_at.to_f,
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

      def plan_from_legacy_path(path, mount_path)
        plan_id = plan_id_from(path, mount_path)
        return unless plan_id

        Plan.includes(:created_by_user, :plan_type, :current_plan_version).find_by(id: plan_id)
      end

      def plan_from_browsable_path(path, mount_path)
        mount = mount_path.to_s.sub(%r{/*\z}, "")
        relative = mount.empty? ? path : path.delete_prefix(mount)
        return if !mount.empty? && relative == path
        return unless relative.start_with?("/")

        # Try the full path first — a plan's slug might literally be "edit"
        # or "history" (see spec/requests/browse_spec.rb). Only when that
        # fails do we strip known sub-page tails and try again, matching
        # the route order the browse controller uses.
        candidates = [ relative ]
        stripped = relative.sub(%r{/(edit|history(/[^/]+)?(/diff)?)?/*\z}, "")
        candidates << stripped if stripped != relative

        candidates.each do |candidate|
          plan = plan_from_browsable_candidate(candidate)
          return plan if plan
        end

        nil
      end

      def plan_from_browsable_candidate(relative)
        match = relative.match(%r{\A/([a-z0-9][a-z0-9-]*)/(.+)/*\z})
        return unless match

        handle = match[1]
        return if Library::RESERVED_HANDLES.include?(handle)

        # Slack sends percent-encoded URLs; decode each segment to match
        # the UTF-8 slugs stored in the database (Unicode slugs are
        # explicitly supported — see CoPlan::Slug).
        slug_path = decode_path_segments(match[2])

        resolve_plan(handle, slug_path)
      end

      def resolve_plan(handle, slug_path)
        result = Urls::Resolve.call(handle: handle, slug_path: slug_path)

        # Follow alias redirects: a renamed plan, folder, or library
        # still resolves via UrlAlias, but Urls::Resolve represents that
        # as redirect_to_path with no plan. Re-resolve the rewritten path.
        if result&.redirect_to_path
          new_handle, _, new_slug_path = result.redirect_to_path.partition("/")
          result = Urls::Resolve.call(handle: new_handle, slug_path: new_slug_path)
        end

        return unless result&.found? && result.plan

        # Urls::Resolve doesn't preload the associations for_plan needs.
        Plan.includes(:created_by_user, :plan_type, :current_plan_version).find_by(id: result.plan.id)
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

      # Percent-encodes each path segment for safe assignment to URI#path=.
      # URI#path= rejects raw non-ASCII (Japanese, Arabic, accented Latin),
      # so Unicode slugs must be encoded on the way out.
      def encode_path_segments(path)
        path.split("/").map { |seg| CGI.escape(seg) }.join("/")
      end

      # Percent-decodes each path segment so encoded Unicode slugs from
      # Slack match the UTF-8 slugs stored in the database.
      def decode_path_segments(path)
        path.split("/").map { |seg| CGI.unescape(seg) }.join("/")
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
