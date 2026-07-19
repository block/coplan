module CoPlan
  module Plans
    # Section-level diff between two markdown documents, used by the
    # "changed since you last looked" one-time highlight on the plan page.
    #
    # Sections are computed on the *rendered* document, not the raw
    # markdown: the content is run through the same Commonmarker pipeline
    # as the page, and a section is everything from one top-level h1–h3
    # element to the next (content before any heading keys as TOP_KEY).
    # That keeps the boundaries and slugs in lockstep with the client
    # (changed_sections_controller walks the rendered DOM the same way),
    # including the cases a raw-markdown scan gets wrong: setext headings,
    # space-indented ATX, info-stringed/nested code fences, HTML entities,
    # and CRLF line endings.
    #
    # Returns the keys of sections that are new or whose rendered body
    # changed — removed sections have nothing left to highlight and are
    # ignored. Keys are slugified heading texts with the same `-2`, `-3`
    # duplicate suffixes as the client. A slug the client can't match
    # just means that section quietly doesn't highlight — the safe failure.
    class ChangedSections
      TOP_KEY = "__top__".freeze
      HEADING_TAGS = %w[h1 h2 h3].freeze

      def self.call(old_content:, new_content:)
        old_sections = sections(old_content)
        sections(new_content).filter_map do |key, body|
          key if !old_sections.key?(key) || old_sections[key] != body
        end
      end

      def self.sections(markdown)
        html = Commonmarker.to_html(
          markdown.to_s.encode("UTF-8"),
          options: { extension: MarkdownHelper::EXTENSION_OPTIONS, render: { unsafe: true } },
          plugins: { syntax_highlighter: nil }
        )

        result = { TOP_KEY => +"" }
        used = Set.new
        current_key = TOP_KEY

        Nokogiri::HTML5.fragment(html).children.each do |node|
          if node.element? && HEADING_TAGS.include?(node.name)
            base = slugify(node.text)
            base = "section" if base.empty?
            key = base
            suffix = 2
            while used.include?(key)
              key = "#{base}-#{suffix}"
              suffix += 1
            end
            used << key
            current_key = key
            result[current_key] = +""
          else
            result[current_key] << node.to_html
          end
        end
        result
      end

      # Mirrors changed_sections_controller's _slug exactly — both sides
      # slugify the rendered heading's text content.
      def self.slugify(text)
        text.downcase
          .gsub(/\s+/, "-")
          .gsub(/[^a-z0-9-]/, "")
          .gsub(/-{2,}/, "-")
          .gsub(/\A-|-\z/, "")
      end
    end
  end
end
