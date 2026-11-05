module CoPlan
  module Urls
    # Resolve a document address, not an arbitrary link containing a plan id.
    # Bases come from the request and the host's configured browser URL, and
    # include the engine mount so another app's paths cannot match our plans.
    class ResolvePlan
      LEGACY_PATH = %r{\Aplans/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/?\z}

      def self.call(url:, bases:)
        new(url:, bases:).call
      end

      def initialize(url:, bases:)
        @url = url
        @bases = bases
      end

      def call
        return unless @url.is_a?(String)

        uri = URI.parse(@url)
        return unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?

        base = @bases.map { |value| URI.parse(value) }.find do |candidate|
          uri.scheme == candidate.scheme && uri.host.casecmp?(candidate.host) &&
            uri.port == candidate.port && uri.path.start_with?("#{candidate.path.chomp('/')}/")
        end
        return unless base

        path = URI::DEFAULT_PARSER.unescape(uri.path.delete_prefix("#{base.path.chomp('/')}/"))
        return unless path.valid_encoding? && !path.include?("\0")

        if (match = LEGACY_PATH.match(path))
          return Plan.find_by(id: match[1])
        end

        handle, _, rest = path.partition("/")
        return if rest.blank?

        result = Resolve.call(handle: handle, slug_path: rest)
        if result.redirect_to_path.present?
          handle, _, rest = result.redirect_to_path.partition("/")
          result = Resolve.call(handle: handle, slug_path: rest)
        end
        result.plan
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
