module CoPlan
  module Slideshows
    # Splits a plan's markdown into slides. Slides are a rendering convention
    # over the document — nothing here is persisted — so this must agree with
    # what the reader sees: boundaries come from the Commonmarker AST, never
    # from regexes over raw lines, so a `---` inside a code fence or under a
    # setext heading never splits.
    #
    # The contract (documented for authors in agent-instructions):
    #   - a top-level thematic break written with dashes (`---`) starts a new
    #     slide; `***`/`___` breaks stay visible rules inside a slide
    #   - HTML comments starting with the word "notes" are speaker notes
    #   - slides with no content (leading `---`, consecutive `---`) are dropped
    #
    # Returns Result:
    #   slides             — [Slide(index:, start_line:, end_line:, source:, notes:)]
    #                        line numbers are 1-based into the original content,
    #                        so per-slide renders can keep checkbox source lines
    #                        document-absolute (render_markdown line_offset:)
    #   definition_blocks  — [DefinitionBlock] for every footnote and
    #                        link-reference definition, in document order.
    #                        Definitions are consumed at parse time, so a slide
    #                        rendered in isolation can't see definitions that
    #                        live on another slide; the renderer prepends the
    #                        blocks a slide needs (SlideshowsHelper#deck_preamble)
    #   shared_definitions — the blocks joined as one markdown string, keeping
    #                        only the document's first definition of each key
    #                        (matching CommonMark, where the first definition
    #                        wins and later ones are ignored)
    class Split
      Slide = Struct.new(:index, :start_line, :end_line, :source, :notes, keyword_init: true)
      DefinitionBlock = Struct.new(:start_line, :end_line, :text, :kind, :key, keyword_init: true)
      Result = Struct.new(:slides, :shared_definitions, :definition_blocks, keyword_init: true)

      # Only contiguous dashes split slides — the one convention every
      # markdown deck tool shares. Spaced forms (`- - -`) and other break
      # characters render as rules within the slide.
      DASH_BREAK = /\A {0,3}-{3,}[ \t]*\z/

      # `<!-- notes: ... -->` or `<!-- notes ... -->`, possibly multi-line.
      # The keyword must be followed by a colon, whitespace, or the comment's
      # end — `<!-- notesque aside -->` is somebody's comment, not a speaker
      # note with the body "que aside".
      NOTES_COMMENT = /\A<!--\s*notes(?::\s*|\s+|(?=-->))(?<body>.*?)\s*-->\s*\z/m

      # Loose gate for a line that could open a link-reference definition.
      # Deliberately permissive (CommonMark allows `[a]:/url` with no space
      # and escaped brackets in labels) — the parser round-trip in
      # pure_definitions? is the real validator.
      LINK_DEFINITION_OPENER = /\A {0,3}\[/

      def self.call(content)
        new(content).call
      end

      def initialize(content)
        # \r is stripped to match the plan write paths (Plans::Create,
        # Plans::ReplaceContent), but raw API text can arrive unnormalized —
        # and a "---\r" break line must still split.
        @content = content.to_s.encode("UTF-8").delete("\r")
      end

      def call
        return Result.new(slides: [], shared_definitions: "", definition_blocks: []) if @content.strip.empty?

        doc = Commonmarker.parse(@content, options: { extension: MarkdownHelper::EXTENSION_OPTIONS })
        lines = @content.split("\n", -1)

        break_lines = []
        footnote_ranges = []
        comment_ranges = []
        paragraph_starts = []
        claimed = Array.new(lines.length + 1, false)

        doc.each do |node|
          pos = node.source_position
          range = (pos[:start_line]..pos[:end_line])
          range.each { |line| claimed[line] = true if line <= lines.length }

          case node.type
          when :thematic_break
            break_lines << pos[:start_line] if lines[pos[:start_line] - 1]&.match?(DASH_BREAK)
          when :footnote_definition
            footnote_ranges << range
          when :html_block
            comment_ranges << range
          when :paragraph
            paragraph_starts << pos[:start_line]
          end
        end

        blocks = definition_blocks(lines, footnote_ranges, claimed, paragraph_starts)

        Result.new(
          slides: build_slides(lines, break_lines, comment_ranges),
          shared_definitions: first_definitions(blocks).map(&:text).join("\n\n"),
          definition_blocks: blocks
        )
      end

      private

      # The document's first definition of each key, in document order —
      # matching how CommonMark resolves duplicated keys.
      def first_definitions(blocks)
        seen = Set.new
        blocks.select { |block| seen.add?(block.key) }
      end

      def build_slides(lines, break_lines, comment_ranges)
        boundaries = [ 0, *break_lines, lines.length + 1 ]
        slides = boundaries.each_cons(2).map do |after, before|
          start_line = after + 1
          end_line = before - 1

          # Trim blank edge lines so slide sources are clean fragments; the
          # line numbers move with the trim, keeping start_line valid as a
          # render offset into the original document.
          start_line += 1 while start_line <= end_line && lines[start_line - 1].strip.empty?
          end_line -= 1 while end_line >= start_line && lines[end_line - 1].strip.empty?
          next if end_line < start_line

          source = lines[(start_line - 1)..(end_line - 1)].join("\n")
          Slide.new(start_line:, end_line:, source:, notes: notes_for(lines, comment_ranges, start_line..end_line))
        end.compact

        slides.each_with_index { |slide, i| slide.index = i + 1 }
        slides
      end

      # Speaker notes are block-level HTML comments (their own lines) whose
      # text starts with "notes". Inline comments inside a paragraph are not
      # scanned — notes are per-slide stage direction, not annotations.
      def notes_for(lines, comment_ranges, slide_range)
        comment_ranges.filter_map do |range|
          next unless slide_range.cover?(range.first) && slide_range.cover?(range.last)

          raw = lines[(range.first - 1)..(range.last - 1)].join("\n")
          match = NOTES_COMMENT.match(raw)
          match && match[:body].strip
        end.reject(&:empty?)
      end

      # Footnote definitions are AST nodes with source positions. Link
      # reference definitions are consumed by the parser: standalone ones
      # appear as runs of lines no top-level node claims, and one written
      # directly above its paragraph is stripped but its line stays inside
      # the paragraph's source span — so paragraph leading lines are checked
      # too.
      def definition_blocks(lines, footnote_ranges, claimed, paragraph_starts)
        blocks = footnote_ranges.map do |range|
          text = lines[(range.first - 1)..(range.last - 1)].join("\n").rstrip
          DefinitionBlock.new(start_line: range.first, end_line: range.last, text: text,
                              kind: :footnote, key: definition_key(:footnote, text))
        end
        blocks.concat(link_definition_blocks(lines, claimed, paragraph_starts))
        blocks.sort_by(&:start_line)
      end

      def link_definition_blocks(lines, claimed, paragraph_starts)
        blocks = []

        # Standalone definitions: runs of unclaimed, non-blank lines. Each
        # block is the longest slice from the current position the parser
        # consumes whole — segments can't simply be cut at `[`-opening lines
        # because a definition title can span lines and its continuation can
        # itself open with `[` (cutting there would fabricate a phantom
        # definition out of the title and lose the real one).
        unclaimed_runs(lines, claimed).each do |first, last|
          position = first
          while position <= last
            fit = last.downto(position).find { |stop| pure_definitions?(lines[(position - 1)..(stop - 1)].join("\n")) }
            unless fit
              position += 1
              next
            end

            text = lines[(position - 1)..(fit - 1)].join("\n")
            blocks << DefinitionBlock.new(start_line: position, end_line: fit, text: text,
                                          kind: :link, key: definition_key(:link, text))
            position = fit + 1
          end
        end

        # Definitions glued to the top of a paragraph (no blank line between
        # definition and text). Only single-line definitions are recognized
        # here; a two-line definition glued to text stays with its home slide.
        paragraph_starts.each do |start|
          line_number = start
          while lines[line_number - 1]&.match?(LINK_DEFINITION_OPENER) && pure_definitions?(lines[line_number - 1])
            text = lines[line_number - 1]
            blocks << DefinitionBlock.new(start_line: line_number, end_line: line_number, text: text,
                                          kind: :link, key: definition_key(:link, text))
            line_number += 1
          end
        end

        blocks
      end

      def unclaimed_runs(lines, claimed)
        runs = []
        run_start = nil
        (1..lines.length + 1).each do |line_number|
          line = lines[line_number - 1]
          if line && !claimed[line_number] && !line.strip.empty?
            run_start ||= line_number
          elsif run_start
            runs << [ run_start, line_number - 1 ]
            run_start = nil
          end
        end
        runs
      end

      # A candidate block is gathered only if the parser consumes it entirely
      # when parsed on its own — that is what keeps `[looks]: like-a-definition`
      # prose (which CommonMark rejects, e.g. unquoted trailing words) from
      # being hoisted onto every slide as visible text.
      #
      # Footnote-shaped lines are refused outright: an UNREFERENCED footnote
      # definition is pruned by the parser both in the document (leaving its
      # lines unclaimed) and here (parsing to an empty AST), so without this
      # guard it would masquerade as a link block — and prepending it back
      # onto its own slide duplicates the definition, which commonmarker
      # punishes by swallowing the whole fragment into the footnotes section.
      def pure_definitions?(text)
        return false unless text.lstrip.start_with?("[")
        return false if text.each_line.any? { |line| line.lstrip.start_with?("[^") }

        Commonmarker.parse(text, options: { extension: MarkdownHelper::EXTENSION_OPTIONS }).first_child.nil?
      end

      # Keys namespace footnotes apart from link references and normalize the
      # label the way CommonMark matches them: collapsed whitespace and
      # Unicode case folding — plain downcase would give `[^straße]` and
      # `[^STRASSE]` different keys while the parser treats them as the same
      # footnote.
      def definition_key(kind, text)
        label = text[/\A {0,3}\[\^?([^\]]+)\]:/, 1].to_s.squish.downcase(:fold)
        label = text if label.empty?
        "#{kind}:#{label}"
      end
    end
  end
end
