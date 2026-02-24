module Plans
  class ReviewResponseParser
    def self.call(response_text, plan_content:)
      new(response_text, plan_content:).call
    end

    def initialize(response_text, plan_content:)
      @response_text = response_text
      @plan_content = plan_content
    end

    def call
      items = parse_json
      items.filter_map { |item| normalize_item(item) }
    end

    private

    def parse_json
      json_text = extract_json_from_response
      parsed = JSON.parse(json_text)

      unless parsed.is_a?(Array)
        return fallback_single_comment
      end

      parsed
    rescue JSON::ParserError
      fallback_single_comment
    end

    def extract_json_from_response
      # Strip markdown code fences if present
      text = @response_text.strip
      if text.start_with?("```")
        text = text.sub(/\A```(?:json)?\s*\n?/, "").sub(/\n?```\s*\z/, "")
      end
      text
    end

    def normalize_item(item)
      return nil unless item.is_a?(Hash)

      anchor = item["anchor_text"].presence
      comment = item["comment"].to_s.strip

      return nil if comment.blank?

      # Verify anchor_text actually exists in the plan content
      if anchor && !@plan_content.include?(anchor)
        # Anchor doesn't match — demote to unanchored with the quote in the comment
        comment = "> #{anchor}\n\n#{comment}"
        anchor = nil
      end

      { anchor_text: anchor, comment: comment }
    end

    def fallback_single_comment
      [{ "anchor_text" => nil, "comment" => @response_text }]
    end
  end
end
