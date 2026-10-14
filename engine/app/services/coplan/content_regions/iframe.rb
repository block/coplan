require "uri"
require "cgi"

module CoPlan
  module ContentRegions
    class Iframe
      PREFIX = "::: {.iframe "
      ATTRIBUTES = %w[src title width height].freeze
      DEFAULTS = { "title" => "Embedded content", "width" => "100%", "height" => "480" }.freeze

      def self.call(source)
        return unless source.start_with?(PREFIX) && source.end_with?(" /}")

        rest = source.delete_prefix(PREFIX).delete_suffix(" /}")
        attrs = {}
        until rest.empty?
          match = /\A([a-z]+)="([^"]*)"(?: +|\z)/.match(rest)
          return unless match && ATTRIBUTES.include?(match[1]) && !attrs.key?(match[1])

          attrs[match[1]] = CGI.unescapeHTML(match[2])
          rest = rest[match[0].length..]
        end
        return unless attrs["src"].present?

        new(DEFAULTS.merge(attrs))
      end

      attr_reader :attributes

      def initialize(attributes)
        @attributes = attributes
      end

      def valid?
        uri = URI.parse(attributes["src"])
        uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.port == 443 &&
          !attributes["src"].match?(/[\\\s]/) &&
          attributes["title"].present? && attributes["title"].length <= 200 &&
          (attributes["width"].match?(/\A(?:[1-9]\d?|100)%\z/) || pixel_size?(attributes["width"], 240..2400)) &&
          pixel_size?(attributes["height"], 160..1600)
      rescue URI::InvalidURIError
        false
      end

      def allowed?(host: nil)
        return false unless valid?

        hostname = URI.parse(attributes["src"]).host.downcase
        return false if hostname == host.to_s.downcase

        EmbedDomain.exists?(hostname: hostname)
      end

      private

      def pixel_size?(value, range)
        value.match?(/\A\d{3,4}\z/) && range.cover?(value.to_i)
      end
    end
  end
end
