module CoPlan
  module Plans
    # Section-level diff between two markdown documents, used by the
    # "changed since you last looked" one-time highlight on the plan page.
    #
    # A section is everything from one ATX heading (h1–h3, matching the
    # TOC's outline levels) to the next; content before any heading keys as
    # TOP_KEY. Returns the keys of sections that are new or whose body
    # changed — removed sections have nothing left to highlight and are
    # ignored.
    #
    # Keys are slugified heading texts using the same algorithm (and the
    # same `-2`, `-3` duplicate suffixes) as the client-side TOC/highlight
    # code, so the browser can map keys back to rendered headings. A slug
    # mismatch (exotic markdown inside a heading) just means that section
    # quietly doesn't highlight — the safe failure.
    class ChangedSections
      TOP_KEY = "__top__".freeze
      HEADING_PATTERN = /\A\#{1,3}\s+(.*?)\s*\#*\s*\z/
      FENCE_PATTERN = /\A\s{0,3}(`{3,}|~{3,})/

      def self.call(old_content:, new_content:)
        old_sections = sections(old_content)
        sections(new_content).filter_map do |key, body|
          # Trailing blank lines shift when a section is added below —
          # that's not a change *in this section*, so compare rstripped.
          key if old_sections[key].rstrip != body.rstrip
        end
      end

      def self.sections(markdown)
        result = Hash.new { |h, k| h[k] = +"" }
        used = Set.new
        current_key = TOP_KEY
        in_fence = false

        markdown.to_s.each_line do |line|
          in_fence = !in_fence if line.match?(FENCE_PATTERN)
          if !in_fence && (match = line.match(HEADING_PATTERN))
            base = slugify(match[1])
            base = "section" if base.blank?
            key = base
            suffix = 2
            while used.include?(key)
              key = "#{base}-#{suffix}"
              suffix += 1
            end
            used << key
            current_key = key
          else
            result[current_key] << line
          end
        end
        result
      end

      # Mirrors content_nav_controller's slugify(textContent): strip the
      # inline markdown that won't survive rendering, then lowercase,
      # hyphenate whitespace, drop everything else.
      def self.slugify(text)
        plain = text
          .gsub(/\[([^\]]*)\]\([^)]*\)/, '\1') # [text](url) -> text
          .gsub(/[`*_~]/, "")
          .gsub(/<[^>]+>/, "")
        plain.downcase
          .gsub(/\s+/, "-")
          .gsub(/[^a-z0-9-]/, "")
          .gsub(/-{2,}/, "-")
          .gsub(/\A-|-\z/, "")
      end
    end
  end
end
