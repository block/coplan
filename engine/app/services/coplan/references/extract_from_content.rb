module CoPlan
  module References
    class ExtractFromContent
      def self.call(plan:, content: nil)
        new(plan:, content:).call
      end

      def initialize(plan:, content: nil)
        @plan = plan
        @content = content
      end

      def call
        content = @content || @plan.current_content
        return remove_all_extracted if content.blank?

        found_urls = extract_urls(content)

        # Remove extracted references for URLs no longer in content
        @plan.references.extracted.where.not(url: found_urls.keys).delete_all

        # Once per distinct URL, not once per mention: a readable address
        # costs a segment walk to turn into an id, so a body full of
        # cross-links to the same document pays for it once.
        #
        # No `own_host` — this runs from a model callback, with no request to
        # ask. A readable address is recognized here by resolving, which is
        # the stronger test anyway.
        links = found_urls.keys.index_with { |url| Reference.resolve_link(url, excluding: @plan.id) }

        # Create or update references for found URLs
        found_urls.each do |url, meta|
          ref_type, target_plan_id = links[url]

          ref = @plan.references.find_or_initialize_by(url: url)
          # Don't overwrite explicit references
          next if ref.persisted? && ref.source == "explicit"

          ref.assign_attributes(
            key: meta[:key].presence || ref.key,
            title: meta[:title].presence || ref.title,
            reference_type: ref_type,
            source: "extracted",
            target_plan_id: target_plan_id
          )
          ref.save!
        end
      end

      private

      def remove_all_extracted
        @plan.references.extracted.delete_all
      end

      def extract_urls(content)
        urls = {}  # url => { title:, key: }

        # Match markdown reference-style link definitions: [key]: url "optional title"
        content.scan(/^\[([^\]]+)\]:\s+(https?:\/\/\S+)(?:\s+"([^"]*)")?/m) do |key, url, title|
          url = url.strip
          k = key.strip.downcase.gsub(/[^a-z0-9_-]/, "-").gsub(/-+/, "-").truncate(64, omission: "")
          urls[url] ||= { title: title&.strip, key: k }
        end

        # Match markdown inline links: [title](url)
        content.scan(/\[([^\]]*)\]\(([^)]+)\)/) do |title, url|
          url = url.strip
          next unless url.match?(%r{\Ahttps?://})
          urls[url] ||= { title: title.strip, key: nil }
        end

        # Match bare URLs that aren't already inside markdown link syntax
        stripped = content.gsub(/\[([^\]]*)\]\(([^)]+)\)/, "").gsub(/^\[([^\]]+)\]:\s+\S+.*$/, "")
        stripped.scan(%r{https?://[^\s<>\]\)]+}) do |url|
          url = url.chomp(".").chomp(",").chomp(")").chomp(";")
          urls[url] ||= { title: nil, key: nil }
        end

        urls
      end
    end
  end
end
