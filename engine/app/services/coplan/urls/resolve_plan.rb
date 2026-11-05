module CoPlan
  module Urls
    # Resolve a document address, not an arbitrary link containing a plan id.
    # The domain is optional and does not affect lookup. Bases supply the
    # engine mount prefix; authorization belongs to the caller.
    class ResolvePlan
      MAX_REDIRECTS = 20
      LEGACY_PATH = %r{\Aplans/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/?\z}

      def self.call(url:, bases:)
        new(url:, bases:).call
      end

      def initialize(url:, bases:)
        @url = url
        @bases = bases
      end

      def call
        return unless @url.is_a?(String) && @url.valid_encoding?

        # Browser address bars display Unicode slugs decoded. Preserve URL
        # delimiters and existing escapes while encoding only non-ASCII text.
        encoded_url = @url.gsub(/[^\x00-\x7F]/) { |char| char.bytes.map { |byte| "%%%02X" % byte }.join }
        uri = URI.parse(encoded_url)
        relative = uri.relative? && uri.host.nil?
        return unless relative || (uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?)

        input_path = uri.path.to_s
        input_path = "/#{input_path}" unless input_path.start_with?("/")

        base = @bases.map { |value| URI.parse(value) }.find do |candidate|
          input_path.start_with?("#{candidate.path.chomp('/')}/")
        end
        return unless base

        path = URI::DEFAULT_PARSER.unescape(input_path.delete_prefix("#{base.path.chomp('/')}/"))
        return unless path.valid_encoding? && !path.include?("\0")

        plan = resolve_path(path)
        return plan if plan

        # A canonical document can itself be named history or edit. Only
        # after full-path lookup fails should a routed subpage be removed.
        document_path = path.sub(%r{(?:/(?:edit|history(?:/\d+(?:/diff)?)?)/?|\.md)\z}, "")
        resolve_path(document_path) if document_path != path
      rescue URI::InvalidURIError
        nil
      end

      private

      def resolve_path(path)
        if (match = LEGACY_PATH.match(path))
          return Plan.find_by(id: match[1])
        end

        visited = []
        MAX_REDIRECTS.times do
          return if visited.include?(path)
          visited << path
          handle, _, rest = path.partition("/")
          return if rest.blank?

          result = Resolve.call(handle: handle, slug_path: rest)
          return result.plan if result.redirect_to_path.blank?

          path = result.redirect_to_path
        end
        nil
      end
    end
  end
end
