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
    def render_slideshow(content, interactive: true, theme: "coplan")
      result = Slideshows::Split.call(content)

      lead_by_slide = {}
      sections = result.slides.map do |slide|
        preamble = deck_preamble(result.definition_blocks, slide)
        # Classify the exact string being rendered — with the preamble,
        # reference-style images resolve to image nodes here the same way
        # they resolve on screen (the sentinel comment classifies as
        # nothing, per SLIDE_SPEC.md's content-sequence rules).
        classification = Slideshows::Classify.call(preamble + slide.source)
        lead_by_slide[slide.index.to_s] = classification.lead
        inner = render_markdown(preamble + slide.source, interactive:, footnotes: :exclude,
                                line_offset: slide.start_line - 1 - preamble.count("\n"))
        tag.section(inner,
                    class: [ "deck-slide", "deck-slide--#{classification.pattern}",
                             "deck-step-#{classification.step}" ],
                    data: { slide: slide.index, pattern: classification.pattern,
                            media: classification.media }.compact)
      end

      # Slides render in isolation, so anything numbered per document —
      # footnote marks, heading-anchor ids, section-N heading ids — restarts
      # on every slide. The document-mode render is the ground truth readers
      # and agents link against; these passes rewrite the deck to match it.
      deck = Nokogiri::HTML::DocumentFragment.parse(safe_join(sections))
      document = Nokogiri::HTML::DocumentFragment.parse(render_markdown(content, interactive: false))
      renumber_deck_footnotes(deck, document)
      align_heading_ids(deck, document)
      mirror_section_link_enhancement(deck, document)
      drop_misleading_ids(deck, document)
      strip_duplicate_ids(deck)
      decorate_slide_content(deck, lead_by_slide)

      tag.div(deck.to_html.html_safe, class: "deck", data: { deck_theme: theme })
    end

    private

    # SLIDE_SPEC.md's markup contract on the rendered DOM: the slide's
    # block container gets the spec's neutral .deck-content name (the
    # design system must not know CoPlan's .markdown-rendered), and split
    # slides get their two pane wrappers. Wrappers add structure only —
    # no text, no reordering — so comment anchors and the parity passes
    # above are unaffected.
    def decorate_slide_content(deck, lead_by_slide)
      deck.css("section.deck-slide > div.markdown-rendered").each { |div| div.add_class("deck-content") }
      wrap_split_slides(deck, lead_by_slide)
    end

    # The classifier promised one media block at the body's edge; find it
    # in the DOM and wrap it and the rest into the split panes. Rendered
    # DOM can disagree with the classified shape (sanitize can delete raw
    # HTML blocks wholesale, or reduce one to a bare text node), so the
    # shape is verified before wrapping — on any mismatch the slide keeps
    # flat markup and the stylesheet degrades to the content layout, per
    # the spec.
    def wrap_split_slides(deck, lead_by_slide)
      deck.css("section.deck-slide--split").each do |section|
        content = section.element_children.find { |el| el.classes.include?("deck-content") }
        next unless content
        # Loose visible text (a raw-HTML block sanitize stripped down to its
        # text) can't be attributed to a pane; wrapping the elements around
        # it would reorder what readers see (spec invariant 2).
        next if content.children.any? { |node| node.text? && !node.text.strip.empty? }

        children = content.element_children.to_a
        # The lead heading is the classifier's lead, not whatever renders
        # first: a raw-HTML heading in the body belongs inside .deck-body,
        # not spanning the panes.
        lead = lead_by_slide[section["data-slide"]]
        next if lead && !children.first&.name&.match?(/\Ah[1-6]\z/)

        pool = lead ? children.drop(1) : children
        next if pool.size < 2

        media = section["data-media"] == "leading" ? pool.first : pool.last
        next unless media_element?(media)

        rest = pool - [ media ]
        media_wrap = content.document.create_element("div", class: "deck-media")
        body_wrap = content.document.create_element("div", class: "deck-body")
        media.add_previous_sibling(media_wrap)
        media_wrap.add_child(media)
        rest.first.add_previous_sibling(body_wrap)
        rest.each { |el| body_wrap.add_child(el) }
      end
    end

    # The DOM shape a classified media block renders to: a paragraph whose
    # only content is an image (alt text is an attribute, so text is
    # blank), or a mermaid fence (comrak carries the info string as lang).
    def media_element?(el)
      return false if el.nil?

      (el.name == "p" && el.at_css("img") && el.text.strip.empty?) ||
        (el.name == "pre" && el["lang"] == "mermaid")
    end

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
    # back matter, which renders once over the whole document: mark N is the
    # Nth item in the document-wide footnotes section (which also counts
    # footnotes referenced only inside other definitions). Anchors merely
    # dressed up as footnote refs (author HTML carrying data-footnote-ref)
    # point at no known definition and pass through untouched, exactly as
    # they do in document mode.
    def renumber_deck_footnotes(deck, document)
      ordinals = {}
      # Direct <ol> children only — the visible back-matter numbering is the
      # list position, and a decoy li[id="fn-…"] smuggled inside a definition
      # body must not claim an ordinal slot.
      document.css(%(section[data-footnotes] > ol > li[id^="fn-"])).each do |li|
        ordinals[li["id"]] ||= ordinals.size + 1
      end

      occurrences = Hash.new(0)
      deck.css("a[data-footnote-ref]").each do |anchor|
        # Genuine commonmarker refs carry an #fnref-… id and a fragment
        # href; author HTML that merely wears data-footnote-ref keeps its
        # own text and id, exactly as it does in document mode. An element
        # claiming to be a heading anchor and a footnote ref at once is
        # author HTML too — comrak never emits both — and counting it here
        # would shift every later real reference off its back-matter
        # backref.
        next if anchor.classes.include?("anchor")
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
    end

    # Heading ids come from two generators, and both dedupe repeats against
    # a single render: comrak names anchor ids intro, intro-1, … and
    # numbered headings get section-N ids suffixed by unique_dom_id. Slide
    # sources are exact line slices of the document cut only at top-level
    # nodes, so the deck's body anchors and headings normally appear in the
    # same order as the document render's — each deck element takes its
    # document-mode attributes positionally, which is what keeps links
    # written against document mode ([jump](#section-1-2)) alive in the
    # deck.
    #
    # Positional copying is only safe when the sequences really are the
    # same elements: author raw HTML left open across a slide break parses
    # differently per slide than in the document (force-closed at the
    # boundary vs foster-parented or swallowed with full context), which
    # can reorder the document sequence. So every pair must also agree on
    # a content fingerprint — a swap of same-content elements is the only
    # kind the check lets through, and copying between elements with
    # identical content is harmless. On any drift, per-slide ids are left
    # alone; strip_duplicate_ids still guarantees an unambiguous fragment
    # target. Footnote-ref anchors are renumber_deck_footnotes' territory
    # and are excluded on both sides.
    def align_heading_ids(deck, document)
      anchor_fingerprint = ->(el) { content_fingerprint(el.parent) }
      heading_fingerprint = ->(el) { content_fingerprint(el) }

      [
        [ "a.anchor", %w[id href], anchor_fingerprint ],
        [ "h1, h2, h3, h4, h5, h6", %w[id], heading_fingerprint ]
      ].each do |selector, attributes, fingerprint|
        document_elements = outside_footnotes(document, selector)
        deck_elements = outside_footnotes(deck, selector)
        next unless document_elements.size == deck_elements.size

        pairs = deck_elements.zip(document_elements)
        next unless pairs.all? { |deck_el, doc_el| fingerprint.call(deck_el) == fingerprint.call(doc_el) }

        pairs.each do |deck_element, document_element|
          attributes.each do |attribute|
            if document_element[attribute]
              deck_element[attribute] = document_element[attribute]
            else
              deck_element.remove_attribute(attribute)
            end
          end
        end
      end
    end

    # Section-preview affordances must match document mode exactly, and an
    # isolated slide render gets them wrong in both directions: it can't
    # see that a #section-… link's target heading lives on another slide
    # (so it misses the enhancement), and it can't see that its own heading
    # loses the section-N id to an earlier claimant elsewhere in the
    # document (so it keeps a stale one). The document render already made
    # every judgment; mirror it — enhance deck links whose target it
    # enhanced, strip the affordance from links it left plain. Author HTML
    # that hand-writes the enhancement attributes can still drift from
    # document mode here; the link navigates either way, only the preview
    # affordance differs.
    def mirror_section_link_enhancement(deck, document)
      section_targets = document.css("a.reference-anchor--section")
                                .map { |anchor| anchor["href"].to_s.delete_prefix("#") }.to_set

      deck.css(%(a[href^="#"])).each do |anchor|
        next if anchor["data-footnote-ref"] || anchor["data-footnote-backref"]

        if section_targets.include?(anchor["href"].delete_prefix("#"))
          enhance_reference_anchor(anchor, type: "section") unless anchor["aria-haspopup"] == "dialog"
        elsif anchor.classes.include?("reference-anchor--section")
          strip_section_enhancement(anchor)
        end
      end
    end

    def strip_section_enhancement(anchor)
      anchor.remove_class("reference-anchor--section")
      anchor.remove_class("reference-anchor")
      anchor.remove_attribute("class") if anchor["class"].to_s.empty?
      anchor.remove_attribute("aria-haspopup")
      anchor.remove_attribute("aria-expanded")
      actions = anchor["data-action"].to_s.sub(MarkdownHelper::REFERENCE_PREVIEW_ACTIONS, "").strip
      actions.empty? ? anchor.remove_attribute("data-action") : anchor["data-action"] = actions
    end

    # What a reader sees or gets at an element: its visible text plus the
    # descendant attributes text is blind to (image sources, link
    # destinations, checkbox states). Heading-anchor hrefs are the one
    # exclusion — they carry the per-render dedup suffix (#intro vs
    # #intro-1), so including them would keep legitimate duplicate headings
    # from ever comparing equal across renders. Footnote-ref hrefs stay in:
    # a genuine ref's #fn-… href is identical in both renders, and an
    # author link merely wearing the attribute is exactly the kind of
    # difference this fingerprint exists to catch.
    def content_fingerprint(el)
      return [] if el.nil?

      links = el.css("a").reject { |a| a.classes.include?("anchor") }
      [ el.name, el.text.squish,
        el.css("img").map { |img| [ img["src"], img["alt"] ] },
        links.map { |a| a["href"] },
        el.css("input").map { |input| input["checked"] } ]
    end

    # Author HTML spanning a slide break can force an alignment skip, or
    # per-slide numbering that happens to coincide with a document id owned
    # by other content. Whatever ids survive to here, a reader following a
    # fragment link must land on what document mode shows: any deck id
    # whose document-mode owner reads differently is dropped rather than
    # left pointing at the wrong thing. Ids the document doesn't have at
    # all are kept — no document-mode link can be betrayed by them.
    def drop_misleading_ids(deck, document)
      owners = {}
      document.css("[id]").each { |el| owners[el["id"]] ||= id_owner_fingerprint(el) }

      deck.css("[id]").each do |el|
        expected = owners[el["id"]]
        el.remove_attribute("id") if expected && expected != id_owner_fingerprint(el)
      end
    end

    # Heading anchors are empty elements — their identity is the heading
    # they mark — so they validate by their parent's content instead of
    # their own.
    def id_owner_fingerprint(el)
      if el.name == "a" && el.classes.include?("anchor")
        content_fingerprint(el.parent)
      else
        content_fingerprint(el)
      end
    end

    # Ids still duplicated after alignment (author-written repeats, or
    # generated ids left per-slide by an alignment drift) resolve to their
    # first occurrence in a browser; strip the later copies so every
    # fragment target is unambiguous.
    def strip_duplicate_ids(deck)
      seen_ids = Set.new
      deck.css("[id]").each do |el|
        el.remove_attribute("id") unless seen_ids.add?(el["id"])
      end
    end

    # The document render's elements outside its footnotes section — the
    # part of the document that deck slides actually show (per-slide
    # rendering excludes footnote sections; their content renders in the
    # plan's References back matter instead).
    def outside_footnotes(fragment, selector)
      fragment.css(selector).reject do |el|
        el["data-footnote-ref"] || el.ancestors("section").any? { |section| section["data-footnotes"] }
      end
    end
  end
end
