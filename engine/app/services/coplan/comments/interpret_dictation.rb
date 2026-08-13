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
      Result = Struct.new(:body, :anchor_text, keyword_init: true)

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
        You process a spoken remark somebody made about a document.

        You are given an excerpt of what was on their screen and a raw
        speech-to-text transcript. Return JSON with exactly two keys:

        {"text": "...", "span": "..."}

        "text": the remark cleaned up into a readable comment.
        - Remove filler words and verbal tics: um, uh, like, you know,
          I mean, sort of, kind of, basically, actually.
        - Repair false starts and repetitions into what they meant to say.
        - Fix obvious mis-transcriptions using the excerpt as context
          (technical terms in the excerpt are almost certainly what they
          said).
        - Keep their meaning, their voice, and their brevity. Do not make
          it formal, do not expand it, do not add points they did not
          make, do not answer or act on it.

        "span": the exact text from the excerpt the remark is about.
        - Copied character-for-character from the excerpt.
        - The smallest span that identifies the target: a phrase or
          sentence, not a whole section.
        - Use null if the remark is about the document as a whole, or you
          cannot identify a specific passage.

        Speech is conversational: the remark may be a follow-up to one of
        the recent comments, if any are given ("oh, I meant both of
        them"). Use them to resolve what "it", "them" or "that one"
        refers to, and fold the reference into "text" so the comment
        stands alone. The span must still come from the excerpt.

        Reply with the JSON object and nothing else.
      PROMPT

      def self.call(...) = new(...).call

      def initialize(excerpt:, transcript:, document: nil, recent_comments: [])
        @excerpt = excerpt.to_s
        # What the anchor ultimately has to resolve against. Defaults to
        # the excerpt so callers that only have the one string still work.
        @document = document.to_s.presence || @excerpt
        @transcript = transcript.to_s.strip
        # [{ body:, anchor: }, ...], newest first — the conversation the
        # remark may be continuing.
        @recent_comments = recent_comments
      end

      def call
        return Result.new(body: @transcript, anchor_text: nil) if @transcript.empty?

        parsed = parse(Ai.call(system_prompt: SYSTEM_PROMPT, user_content: user_content))
        Result.new(
          body: cleaned_text(parsed["text"]),
          anchor_text: verbatim_span(parsed["span"])
        )
      rescue Ai::Error => e
        # Both halves are enhancements; a local tidy-up of what they said
        # is still better than nothing.
        Rails.logger.info("[coplan] dictation interpretation unavailable: #{e.message}")
        Result.new(body: fallback_text, anchor_text: nil)
      end

      private

      def user_content
        <<~CONTENT
          Excerpt:
          ---
          #{@excerpt}
          ---
          #{comments_section}
          Transcript: #{@transcript}
        CONTENT
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

      def cleaned_text(text)
        text = text.to_s.strip
        return fallback_text if text.empty?

        ratio = text.length.to_f / @transcript.length
        return fallback_text unless ratio.between?(MIN_LENGTH_RATIO, MAX_LENGTH_RATIO)

        text
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

      # The excerpt is the rendered text of what was on screen; the anchor
      # has to resolve against the markdown source, and the two differ
      # anywhere the source carries markup. A table renders its cells as
      # adjacent lines ("Voice (mic button)\n24%" appears nowhere in
      # "| Voice (mic button) | 24% |"), and inline markup breaks even a
      # single line — "main is always releasable" is not a substring of
      # "`main` is always releasable". An anchor that doesn't resolve
      # isn't a bad pin, it's an invisible comment, so degrade in steps:
      # whole span, then whole lines, then the longest run of words that
      # still appears in the source.
      def anchorable(span)
        return span if @document.include?(span)

        lines = span.split("\n").map(&:strip).reject(&:empty?)
        whole_lines = lines.select { |line| @document.include?(line) }
        return whole_lines.max_by(&:length) if whole_lines.any?

        lines.flat_map { |line| word_runs(line) }
          .select { |run| run.length >= MIN_ANCHOR_LENGTH && @document.include?(run) }
          .max_by(&:length)
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
