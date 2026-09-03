module CoPlan
  module Comments
    # Turns what somebody said into a comment worth reading: the words
    # tidied up, and the passage they were talking about.
    #
    # Both halves need the same two inputs — the transcript and what was
    # on screen — so they're one call. Speech is full of false starts
    # ("put the medium weight latency I put the like the speed"), and a
    # remark like "this bit is too cautious" only means something next to
    # the text it's pointing at.
    #
    # Neither half is trusted:
    #   - a span that isn't in the excerpt character-for-character is a
    #     paraphrase, and a paraphrase can't be highlighted
    #   - a rewrite that changes length dramatically has stopped being a
    #     cleanup and started being a summary
    # Anything that fails a check falls back to what the person said.
    class InterpretDictation
      Comment = Struct.new(:body, :anchor_text, keyword_init: true)

      # One remark is usually one comment, but "rename both of these" is
      # two placements. The first comment doubles as the whole result for
      # callers that predate the plural.
      Result = Struct.new(:comments, keyword_init: true) do
        def body = comments.first&.body
        def anchor_text = comments.first&.anchor_text
      end

      # A spoken remark that genuinely makes more points than this has
      # stopped being a remark; past the cap the rest is folded away.
      MAX_COMMENTS = 4

      # Standing alone costs words: "rename both of them" becomes two full
      # sentences. The cost is roughly a short sentence per split — a
      # constant, not a multiple of however long the remark was.
      PER_COMMENT_HEADROOM = 40

      # Long enough to be unambiguous, short enough that the highlight
      # reads as a pointer rather than a block quote.
      MAX_ANCHOR_LENGTH = 300

      # A tidy-up keeps roughly the same words. Outside this band it's
      # either dropping content or padding it.
      MIN_LENGTH_RATIO = 0.4
      MAX_LENGTH_RATIO = 1.6

      # The floor for a salvaged fragment of a span. Below this it's a
      # stray "is" or "the" — a pin on one of those points at noise.
      MIN_ANCHOR_LENGTH = 8

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You turn a spoken remark somebody made about a document into the
        comment they meant to leave on it.

        You are given an excerpt of what was on their screen and a raw
        speech-to-text transcript. Return JSON of this shape:

        {"comments": [{"text": "...", "span": "..."}]}

        Almost always one comment. Split into several ONLY when the remark
        clearly makes the same point about more than one passage ("rename
        both of these", "each of these headings") or makes clearly
        separate points about separate passages. Never more than four. To
        point at two copies of the same text, repeat the span in two
        comments.

        "text": the comment as the speaker would have typed it.
        - It is their comment, in their voice, from their point of view,
          and it will appear under their name. You edit their words; you
          are not a participant in the conversation. Never reply to the
          remark, never answer a question it asks, never promise action.
          "Hmm, not enough information on tax attach" becomes "Not enough
          information on tax attach." — rewriting it as "I will add more
          information" would sign a promise in their name that they never
          made.
        - Remove filler words and verbal tics: hmm, um, uh, like,
          you know, I mean, sort of, kind of, basically, actually.
        - Repair false starts and repetitions into what they meant to say.
        - Fix obvious mis-transcriptions using the excerpt as context
          (technical terms in the excerpt are almost certainly what they
          said).
        - Keep their meaning, their voice, and their brevity. Do not make
          it formal, do not expand it, do not add points they did not
          make, do not answer or act on it.

        "span": the exact text from the excerpt the remark is about.
        - Copied character-for-character from the excerpt.
        - The remark usually names its own target: when it mentions words
          that appear in the excerpt ("tax attach"), the span is the
          passage containing them.
        - The smallest span that identifies the target: a phrase or
          sentence, not a whole section.
        - People read near the middle of their screen. When a "they were
          reading" section is given, the target is most likely in it; the
          rest of the excerpt is context that scrolled past while they
          spoke.
        - Use null if the remark is about the document as a whole, or you
          cannot identify a specific passage.

        Speech is conversational: the remark may be a follow-up to one of
        the recent comments, if any are given ("oh, I meant both of
        them"). Use them to resolve what "it", "them" or "that one"
        refers to, and fold the reference into "text" so each comment
        stands alone. Spans must still come from the excerpt.

        Reply with the JSON object and nothing else.
      PROMPT

      def self.call(...) = new(...).call

      def initialize(excerpt:, transcript:, document: nil, recent_comments: [], focus: nil)
        @excerpt = excerpt.to_s
        # What the anchor ultimately has to resolve against. Defaults to
        # the excerpt so callers that only have the one string still work.
        @document = document.to_s.presence || @excerpt
        @transcript = transcript.to_s.strip
        # [{ body:, anchor: }, ...], newest first — the conversation the
        # remark may be continuing.
        @recent_comments = recent_comments
        # What was mid-screen when they finished speaking. The excerpt
        # accumulates everything that scrolled past during the take, so
        # without this the model has no idea which part of it the person
        # was actually reading.
        @focus = focus.to_s.strip
      end

      def call
        return Result.new(comments: [ Comment.new(body: @transcript, anchor_text: nil) ]) if @transcript.empty?

        parsed = parse(Ai.call(system_prompt: SYSTEM_PROMPT, user_content: user_content))
        Result.new(comments: comments_from(parsed))
      rescue Ai::Error => e
        # Both halves are enhancements; a local tidy-up of what they said
        # is still better than nothing.
        Rails.logger.info("[coplan] dictation interpretation unavailable: #{e.message}")
        Result.new(comments: [ Comment.new(body: fallback_text, anchor_text: nil) ])
      end

      private

      def user_content
        <<~CONTENT
          Excerpt:
          ---
          #{@excerpt}
          ---
          #{focus_section}#{comments_section}
          Transcript: #{@transcript}
        CONTENT
      end

      # Omitted when it adds nothing: no focus reported, or the excerpt
      # fit on one screen so "what they were reading" is the whole thing.
      def focus_section
        return "" if @focus.blank? || @focus == @excerpt.strip

        <<~SECTION
          They were reading this part as they finished speaking (the span is usually in here):
          ---
          #{@focus}
          ---
        SECTION
      end

      def comments_section
        return "" if @recent_comments.blank?

        lines = @recent_comments.map.with_index(1) do |comment, i|
          anchor = comment[:anchor].presence
          body = comment[:body].to_s.truncate(200)
          anchor ? %(#{i}. (on "#{anchor.truncate(60)}") #{body}) : "#{i}. #{body}"
        end

        <<~SECTION

          Recent comments on this document, newest first:
          ---
          #{lines.join("\n")}
          ---
        SECTION
      end

      def parse(response)
        # Models wrap JSON in code fences regardless of instructions.
        json = response.to_s.strip.gsub(/\A```(?:json)?\s*|\s*```\z/, "")
        parsed = JSON.parse(json)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def comments_from(parsed)
        # Accept the plural shape, or the old single {"text","span"} a
        # model may still produce.
        items = parsed["comments"].is_a?(Array) ? parsed["comments"] : [ parsed ]
        items = items.first(MAX_COMMENTS).select { |item| item.is_a?(Hash) && item["text"].present? }
        return [ Comment.new(body: fallback_text, anchor_text: nil) ] if items.empty?

        # The length band is the same trust check as ever, applied to the
        # rewrite as a whole: however it was split, the comments together
        # should say roughly what the person said — much shorter is a
        # summary, much longer is invention. Each extra comment earns
        # PER_COMMENT_HEADROOM on the high side for its standing-alone
        # overhead.
        combined = items.sum { |item| item["text"].to_s.strip.length }
        min_length = @transcript.length * MIN_LENGTH_RATIO
        max_length = @transcript.length * MAX_LENGTH_RATIO + (items.length - 1) * PER_COMMENT_HEADROOM
        unless combined.between?(min_length, max_length)
          return [ Comment.new(body: fallback_text, anchor_text: nil) ]
        end

        items.map do |item|
          Comment.new(body: item["text"].to_s.strip, anchor_text: verbatim_span(item["span"]))
        end
      end

      # The floor when the model can't be reached or its rewrite is
      # rejected: drop the tics that stand alone as words and collapse
      # stutters. Conservative on purpose — "like" is a real word ("looks
      # like the API"), so it only goes when it is clearly filler, and
      # nothing here reorders or rewrites.
      def fallback_text
        cleaned = @transcript
          .gsub(/\b(?:um+|uh+|er+|hmm+)\b,?\s*/i, "")
          .gsub(/\b(?:you know|i mean|sort of|kind of|basically)\b,?\s*/i, "")
          .gsub(/\blike\b,?\s+(?=like\b)/i, "")
          # A comma before "like" marks it as filler — "it looks like the
          # API" has no comma, "this is, like, vague" does.
          .gsub(/,\s*like\b,?\s*/i, " ")
          .gsub(/\b(\w+)(\s+\1\b)+/i, '\1')
          .gsub(/\s{2,}/, " ")
          .gsub(/\s+([,.!?])/, '\1')
          .strip

        return @transcript if cleaned.empty?

        cleaned.sub(/\A./) { |c| c.upcase }
      end

      def verbatim_span(span)
        span = span.to_s.strip
        return nil if span.empty? || span.casecmp("null").zero?
        return nil if span.length > MAX_ANCHOR_LENGTH

        candidate = span if @excerpt.include?(span)
        # Models wrap spans in quotes even when told not to; that much we
        # forgive. Anything else isn't in the document.
        candidate ||= begin
          trimmed = span.gsub(/\A[\s"'“”‘’]+|[\s"'“”‘’]+\z/, "").presence
          trimmed if trimmed && @excerpt.include?(trimmed)
        end

        candidate && anchorable(candidate)
      end

      # An anchor has to live in two representations at once: findable in
      # the rendered page (that's what the highlighter searches) and
      # resolvable to positions in the markdown source (CommentThread
      # handles that, including a stripped-markdown fallback for inline
      # markup like "`main` is always releasable"). The model quotes from
      # the rendered excerpt, so the second half is the one to check —
      # with the resolver's own translation, not a cruder one.
      #
      # The one thing the highlighter cannot do is cross block boundaries:
      # a span covering two table cells ("Voice (mic button)\n24%") has no
      # contiguous home in the DOM. So a multi-line span degrades to its
      # longest resolvable line, and an unresolvable line to its longest
      # resolvable run of words. An anchor that fails everything is
      # dropped — the caller falls back to the section heading, which is
      # a worse pin but a visible one.
      def anchorable(span)
        lines = span.split("\n").map(&:strip).reject(&:empty?)
        return span if lines.length == 1 && resolvable?(span)

        whole_lines = lines.select { |line| resolvable?(line) }
        return whole_lines.max_by(&:length) if whole_lines.any?

        lines.flat_map { |line| word_runs(line) }
          .select { |run| run.length >= MIN_ANCHOR_LENGTH && resolvable?(run) }
          .max_by(&:length)
      end

      def resolvable?(text)
        @document.include?(text) || stripped_document.include?(text)
      end

      def stripped_document
        @stripped_document ||= CommentThread.strip_markdown(@document).first
      end

      # Every contiguous run of words in the line. ~n²/2 candidates for n
      # words, and MAX_ANCHOR_LENGTH caps n well under coffee-break size.
      def word_runs(line)
        words = line.split(/\s+/)
        (0...words.length).flat_map do |from|
          (from...words.length).map { |to| words[from..to].join(" ") }
        end
      end
    end
  end
end
