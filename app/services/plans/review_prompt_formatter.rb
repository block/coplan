module Plans
  class ReviewPromptFormatter
    RESPONSE_FORMAT_INSTRUCTIONS = <<~INSTRUCTIONS.freeze
      You MUST respond with a JSON array of feedback items. Each item is an object with two keys:
      - "anchor_text": An exact substring copied verbatim from the plan document that this feedback applies to. Keep it short (a phrase or single sentence). Must match the plan text exactly. Use null for general feedback not tied to specific text.
      - "comment": Your feedback in Markdown. Be concise and actionable.

      Example response:
      ```json
      [
        {"anchor_text": "API tokens scoped to a user", "comment": "Consider adding token expiration by default. Long-lived tokens without expiry are a common security risk."},
        {"anchor_text": null, "comment": "Overall the plan looks solid. One general concern: there's no mention of audit logging for administrative actions."}
      ]
      ```

      Return ONLY the JSON array. No other text before or after it.
    INSTRUCTIONS

    def self.call(reviewer_prompt:)
      "#{reviewer_prompt}\n\n#{RESPONSE_FORMAT_INSTRUCTIONS}"
    end
  end
end
