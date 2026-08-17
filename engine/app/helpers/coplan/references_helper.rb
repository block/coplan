module CoPlan
  module ReferencesHelper
    include MarkdownHelper

    def reference_domain(url)
      URI.parse(url).host&.delete_prefix("www.")
    rescue URI::InvalidURIError
      nil
    end

    def reference_type_label(reference_type, url)
      domain = reference_domain(url)

      case reference_type
      when "plan" then "CoPlan plan"
      when "repository" then "GitHub repository"
      when "pull_request" then "GitHub pull request"
      when "document"
        return "Google Sheet" if domain == "docs.google.com" && URI.parse(url).path.start_with?("/spreadsheets/")
        return "Google Slides" if domain == "docs.google.com" && URI.parse(url).path.start_with?("/presentation/")
        return "Google Doc" if domain == "docs.google.com"
        return "Google Drive" if domain == "drive.google.com"
        return "Notion" if domain&.end_with?("notion.so", "notion.site")
        return "Confluence" if domain&.include?("confluence")

        "Document"
      else
        domain&.match?(/(^|\.)gov(\.|$)/) ? "Government website" : "Website"
      end
    rescue URI::InvalidURIError
      reference_type.humanize
    end

    # Markdown owns a citation's placement and explanatory text; Reference
    # owns the linked resource's durable identity. Join those two projections
    # by URL for one reader-facing References section without duplicating the
    # versioned plan content in another model.
    def plan_citation_back_matter(plan, references)
      references = references.to_a
      reference_digest = Digest::SHA256.hexdigest(
        references.map { |reference| "#{reference.id}:#{reference.updated_at&.to_f}" }.join("|")
      )
      signature = [ plan.current_revision, reference_digest ]
      cached = Rails.cache.fetch([
        "coplan/plan-citation-back-matter",
        MarkdownHelper::RENDER_CACHE_VERSION,
        plan.id,
        *signature
      ]) do
        result = build_plan_citation_back_matter(plan, references)
        [ result[:html].to_s, result[:cited_urls].to_a, result[:count] ]
      end

      {
        html: cached[0].html_safe,
        cited_urls: cached[1].to_set.freeze,
        count: cached[2]
      }
    end

    def listed_plan_references(references, cited_urls)
      references.reject { |reference| cited_urls.include?(reference.url) }
    end

    def plan_reference_count(plan, references)
      back_matter = plan_citation_back_matter(plan, references)
      back_matter[:count] + listed_plan_references(references, back_matter[:cited_urls]).size
    end

    private

    def build_plan_citation_back_matter(plan, references)
      html = render_markdown(plan.current_content, footnotes: :only)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      sections = doc.css("section[data-footnotes]")
      return { html: "".html_safe, cited_urls: Set.new.freeze, count: 0 } if sections.empty?

      references_by_url = references.index_by(&:url)
      cited_urls = Set.new

      sections.each do |section|
        section["class"] = "reference-citations"
        section.css(".footnotes-title").remove
        section.css('a[href^="http://"], a[href^="https://"]').each do |anchor|
          reference = references_by_url[anchor["href"]]
          cited_urls << anchor["href"]
          decorate_citation_source(anchor, reference)
        end
      end

      {
        html: sections.map(&:to_html).join.html_safe,
        cited_urls: cited_urls.freeze,
        count: sections.sum { |section| section.xpath("./ol/li").size }
      }
    end

    def decorate_citation_source(anchor, reference)
      type = reference&.reference_type || anchor["data-reference-type"] || Reference.classify_url(anchor["href"])
      domain = reference_domain(anchor["href"])
      title = reference&.title.presence || anchor.text.squish.presence || domain || anchor["href"]
      metadata = [ reference_type_label(type, anchor["href"]), domain ].compact.join(" · ")

      anchor.add_class("citation-source")
      anchor["aria-label"] = "Open source: #{title} in a new tab (#{metadata})"
      unless terminal_citation_source?(anchor)
        anchor.add_class("citation-source--inline")
        anchor["title"] = metadata
        return
      end

      anchor.add_class("citation-source--block")
      anchor.children.remove

      content = Nokogiri::XML::Node.new("span", anchor.document)
      content["class"] = "citation-source__content"

      title_node = Nokogiri::XML::Node.new("span", anchor.document)
      title_node["class"] = "citation-source__title"
      title_node.content = title

      metadata_node = Nokogiri::XML::Node.new("span", anchor.document)
      metadata_node["class"] = "citation-source__meta"
      metadata_node.content = "#{metadata} ↗"

      content.add_child(title_node)
      content.add_child(metadata_node)
      anchor.add_child(content)

      punctuation = anchor.next_sibling
      if punctuation&.text? && punctuation.text.match?(/\A\s*[.,;:]\s*\z/)
        punctuation.remove
      end
    end

    def terminal_citation_source?(anchor)
      anchor.xpath("following-sibling::node()").all? do |sibling|
        if sibling.text?
          sibling.text.match?(/\A\s*[.,;:]*\s*\z/)
        else
          sibling.attribute("data-footnote-backref").present?
        end
      end
    end
  end
end
