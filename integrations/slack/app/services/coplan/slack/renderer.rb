module CoPlan
  module Slack
    class Renderer
      def self.call(preview, url: preview.canonical_url)
        section = {
          type: "section",
          text: { type: "mrkdwn", text: "*<#{escape_url(url)}|#{escape(preview.title)}>*#{description(preview)}" }
        }
        section[:accessory] = { type: "image", image_url: preview.image_url, alt_text: preview.title.to_s.first(2000) } if preview.image_url.present?
        {
          fallback: [ preview.title, preview.description, preview.context ].compact.join(" — ").first(3000),
          blocks: [
            section,
            { type: "context", elements: [ { type: "mrkdwn", text: escape(preview.context) } ] }
          ],
          preview: {
            title: { type: "plain_text", text: preview.title.to_s.first(150) }
          }
        }
      end

      def self.escape(value)
        value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      def self.escape_url(value)
        value.to_s.gsub("&", "&amp;").gsub("|", "%7C").gsub(">", "%3E")
      end

      def self.description(preview)
        preview.description.present? ? "\n#{escape(preview.description)}" : ""
      end
      private_class_method :escape_url, :description
    end
  end
end
