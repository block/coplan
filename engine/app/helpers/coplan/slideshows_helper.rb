module CoPlan
  # Deck rendering. Sits beside MarkdownHelper rather than inside it on
  # purpose: everything deck-specific lives in the deck namespace (this
  # helper, the Slideshows::* services, the deck-* classes) with no hooks
  # into document rendering, so the layout engine can be extracted as a
  # standalone spec + stylesheet later.
  module SlideshowsHelper
    include MarkdownHelper

    # Renders a slideshow plan's markdown as a stack of slide sections.
    # Each slide renders through the same pipeline documents use — same
    # sanitization, mentions, interactive checkboxes — so review features
    # keep working. The deck adds structure *around* the content, never
    # visible text inside it: comment anchors count visible-text
    # occurrences, and slide wrappers must not change the count.
    #
    # Footnote sections are excluded per slide (shared definitions are added
    # to every fragment so references still resolve); footnotes render once,
    # document-wide, in the plan's References back matter, exactly as they
    # do for documents.
    def render_slideshow(content, interactive: true)
      result = Slideshows::Split.call(content)

      sections = result.slides.map do |slide|
        preamble = deck_preamble(result.definition_blocks, slide)
        inner = render_markdown(preamble + slide.source, interactive:, footnotes: :exclude,
                                line_offset: slide.start_line - 1 - preamble.count("\n"))
        tag.section(inner, class: "deck-slide", data: { slide: slide.index })
      end

      tag.div(renumber_deck_footnotes(safe_join(sections), content), class: "deck")
    end

    private

    # Definitions are prepended, not appended: a slide ending in an unclosed
    # code fence would swallow an appended block into visible text, and
    # prepending lets the document's first definition of a duplicated key
    # win on every slide, as it does in document mode. Footnote keys the
    # slide defines itself are skipped — commonmarker reacts to a duplicated
    # footnote definition by swallowing the whole fragment into the
    # footnotes section (which per-slide rendering then excludes). Link
    # definitions are inert as duplicates and always prepend. The comment
    # sentinel closes a trailing footnote definition so it can't absorb
    # indented slide content as a continuation; sanitize strips it from the
    # output.
    def deck_preamble(blocks, slide)
      slide_range = slide.start_line..slide.end_line
      local_footnotes = blocks.select { |b| b.kind == :footnote && slide_range.cover?(b.start_line) }.map(&:key).to_set

      seen = Set.new
      chosen = blocks.select { |b| !local_footnotes.include?(b.key) && seen.add?(b.key) }
      return "" if chosen.empty?

      "#{chosen.map(&:text).join("\n\n")}\n\n<!-- deck definitions -->\n\n"
    end

    # The deck must show the same footnote numbers as the plan's References
    # back matter, which renders once over the whole document. Slides render
    # in isolation — numbering restarts at 1 and repeat references reuse
    # commonmarker's per-fragment ids — so this pass rewrites both from the
    # back matter itself: mark N is the Nth item in the document-wide
    # footnotes section (which also counts footnotes referenced only inside
    # other definitions). Anchors merely dressed up as footnote refs
    # (author HTML carrying data-footnote-ref) point at no known definition
    # and pass through untouched, exactly as they do in document mode.
    def renumber_deck_footnotes(html, content)
      ordinals = {}
      back_matter = render_markdown(content, interactive: false, footnotes: :only)
      # Direct <ol> children only — the visible back-matter numbering is the
      # list position, and a decoy li[id="fn-…"] smuggled inside a definition
      # body must not claim an ordinal slot.
      Nokogiri::HTML::DocumentFragment.parse(back_matter).css(%(section[data-footnotes] > ol > li[id^="fn-"])).each do |li|
        ordinals[li["id"]] ||= ordinals.size + 1
      end

      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      occurrences = Hash.new(0)

      doc.css("a[data-footnote-ref]").each do |anchor|
        # Genuine commonmarker refs carry an #fnref-… id and a fragment
        # href; author HTML that merely wears data-footnote-ref keeps its
        # own text and id, exactly as it does in document mode.
        next unless anchor["href"].to_s.start_with?("#") && anchor["id"].to_s.start_with?("fnref-")

        name = anchor["href"].delete_prefix("#")
        next unless ordinals.key?(name)

        anchor.content = ordinals[name].to_s
        # Reproduce document-mode reference ids (fnref-a, fnref-a-2, ...) so
        # every ↩ backref in the back matter lands on a slide.
        occurrences[name] += 1
        suffix = occurrences[name] == 1 ? "" : "-#{occurrences[name]}"
        anchor["id"] = "fnref-#{name.delete_prefix("fn-")}#{suffix}"
      end

      # Slides render in isolation, so cross-slide id collisions are still
      # possible (identical heading anchors); browsers resolve a fragment to
      # its first occurrence, so only the first keeps the id.
      seen_ids = Set.new
      doc.css("[id]").each do |el|
        el.remove_attribute("id") unless seen_ids.add?(el["id"])
      end

      doc.to_html.html_safe
    end
  end
end
