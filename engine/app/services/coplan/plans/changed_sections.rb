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
    #
    # Past a point the highlights stop being worth drawing: if you glanced
    # at a plan while the agent was still drafting it, or the agent rewrote
    # the thing, every section differs and the page turns into one big
    # band. That case comes back as `rewritten?` with no keys — the page
    # says so in a line of text instead of highlighting everything.
    class ChangedSections
      TOP_KEY = "__top__".freeze
      HEADING_TAGS = %w[h1 h2 h3].freeze
      # "Most of it changed" — measured against both the section count and
      # the volume of text, since either alone misreads a common shape: a
      # swarm of one-line sections changing isn't a rewrite, and neither is
      # one long section getting edited.
      REWRITE_RATIO = 0.5
      # Below this, highlighting everything is only a few inches of tint —
      # legible, and more useful than a sentence about it. The notice is
      # for documents long enough that a full-page band reads as noise.
      REWRITE_MIN_SECTIONS = 4

      Result = Struct.new(:keys, :rewritten, keyword_init: true) do
        def rewritten?
          rewritten
        end
      end

      NONE = Result.new(keys: [].freeze, rewritten: false).freeze

      def self.call(old_content:, new_content:)
        old_sections = sections(old_content)
        # An empty lead-in isn't a section; counting it would skew the
        # rewrite ratio on every document that opens with a heading.
        new_sections = sections(new_content).reject { |key, body| key == TOP_KEY && body.empty? }

        changed = new_sections.filter_map do |key, body|
          key if !old_sections.key?(key) || old_sections[key] != body
        end
        return NONE if changed.empty?
        return Result.new(keys: [], rewritten: true) if rewritten?(new_sections, changed)

        Result.new(keys: changed, rewritten: false)
      end

      def self.rewritten?(new_sections, changed)
        return false if new_sections.size < REWRITE_MIN_SECTIONS
        return false unless changed.size > new_sections.size * REWRITE_RATIO

        total = new_sections.sum { |_key, body| body.length }
        return true if total.zero?

        changed.sum { |key| new_sections[key].length } > total * REWRITE_RATIO
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
