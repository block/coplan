module CoPlan
  module Slack
    class Renderer
      BRAND_COLOR = "#136FF5"
      PRIVATE_COLOR = "#8C4AF6"
      ARCHIVED_COLOR = "#64748B"

      def self.call(preview, url: preview.canonical_url)
        section = {
          type: "section",
          text: { type: "mrkdwn", text: "*<#{escape_url(url)}|#{escape(preview.title)}>*#{description(preview)}" }
        }
        section[:accessory] = { type: "image", image_url: preview.image_url, alt_text: preview.title.to_s.first(2000) } if preview.image_url.present?
        {
          color: accent_color(preview),
          fallback: [ preview.title, preview.description, preview.context ].compact.join(" — ").first(3000),
          blocks: [
            section,
            { type: "context", elements: context_elements(preview) }
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

      def self.accent_color(preview)
        return ARCHIVED_COLOR if preview.context.to_s.start_with?("Archived")
        return PRIVATE_COLOR if preview.context.to_s.start_with?("Private")

        BRAND_COLOR
      end

      def self.decorated_context(preview)
        context = escape(preview.context)
        return "📄 #{context}" if preview.author_name.blank?

        author = escape(preview.author_name)
        details = context.delete_suffix(" · by #{author}").delete_suffix("by #{author}")
        if preview.context.to_s.start_with?("Archived")
          details = details.delete_prefix("Archived").delete_prefix(" · ")
          return [ "*#{author}*", details.presence, "📦 Archived" ].compact.join(" · ")
        end
        if preview.context.to_s.start_with?("Private")
          details = details.delete_prefix("Private").delete_prefix(" · ")
          return [ "*#{author}*", details.presence, "🔒 Private" ].compact.join(" · ")
        end

        [ "*#{author}*", details.presence ].compact.join(" · ")
      end

      def self.context_elements(preview)
        elements = []
        if preview.author_avatar_url.present?
          elements << { type: "image", image_url: preview.author_avatar_url, alt_text: preview.author_name.to_s.first(2000) }
        end
        elements << { type: "mrkdwn", text: decorated_context(preview) }
      end
      private_class_method :escape_url, :description, :accent_color, :decorated_context, :context_elements
    end
  end
end
