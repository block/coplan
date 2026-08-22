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

        # Classify once and resolve once. A readable `/l/…` link costs a
        # segment walk to turn into an id, so doing it per-URL rather than
        # per-mention keeps a body full of cross-links cheap.
        types = found_urls.keys.index_with { |url| Reference.classify_url(url) }
        candidates = {}
        types.each do |url, type|
          next unless type == "plan"
          id = Reference.extract_target_plan_id(url)
          candidates[url] = id if id.present? && id != @plan.id
        end
        existing_plan_ids = candidates.any? ? Plan.where(id: candidates.values).pluck(:id).to_set : Set.new

        # Create or update references for found URLs
        found_urls.each do |url, meta|
          ref_type = types[url]
          candidate_id = candidates[url]
          target_plan_id = candidate_id if candidate_id && existing_plan_ids.include?(candidate_id)

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
