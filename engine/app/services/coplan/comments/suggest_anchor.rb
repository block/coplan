module CoPlan
  module Comments
    # Turns "this bit is way too formal" into the exact words it's about.
    #
    # Spoken feedback names its target loosely — "this paragraph", "the
    # bit about rollout", "that last sentence". A heading-level anchor
    # gets you to the right neighbourhood; asking a model which span the
    # remark refers to gets you the sentence itself, so the highlight
    # lands on what the person actually meant.
    #
    # The model is never trusted: it paraphrases, and a paraphrase can't
    # be highlighted. Whatever comes back has to appear verbatim in the
    # text we sent, or we return nil and the caller keeps its fallback.
    class SuggestAnchor
      # Long enough to be unambiguous, short enough that the highlight
      # reads as a pointer rather than a block quote.
      MAX_ANCHOR_LENGTH = 300

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You locate the passage a spoken remark refers to.

        You are given an excerpt of a document and a remark somebody said
        out loud while looking at it. Return the exact span of text from
        the excerpt that the remark is about.

        Rules:
        - Reply with the span only. No quotes, no commentary, no markdown.
        - The span MUST be copied character-for-character from the excerpt.
        - Prefer the smallest span that unambiguously identifies the target:
          a sentence or clause, not a whole section.
        - If the remark is about the document as a whole, or you cannot
          identify a specific span, reply with exactly: NONE
      PROMPT

      def self.call(...) = new(...).call

      def initialize(excerpt:, transcript:)
        @excerpt = excerpt.to_s
        @transcript = transcript.to_s
      end

      def call
        return nil if @excerpt.strip.empty? || @transcript.strip.empty?

        suggestion = Ai.call(system_prompt: SYSTEM_PROMPT, user_content: user_content).to_s.strip
        return nil if suggestion.empty? || suggestion == "NONE"
        return nil if suggestion.length > MAX_ANCHOR_LENGTH

        verbatim(suggestion)
      rescue Ai::Error => e
        # Anchoring is an enhancement; the caller always has a fallback.
        Rails.logger.info("[coplan] anchor suggestion unavailable: #{e.message}")
        nil
      end

      private

      def user_content
        <<~CONTENT
          Excerpt:
          ---
          #{@excerpt}
          ---

          Remark: #{@transcript}
        CONTENT
      end

      # Models wrap spans in quotes even when told not to. That much we
      # forgive; anything else that isn't in the excerpt character-for-
      # character is a paraphrase, and a paraphrase can't be highlighted.
      def verbatim(suggestion)
        return suggestion if @excerpt.include?(suggestion)

        trimmed = suggestion.gsub(/\A[\s"'“”‘’]+|[\s"'“”‘’]+\z/, "")
        return trimmed if trimmed.present? && @excerpt.include?(trimmed)

        nil
      end
    end
  end
end
