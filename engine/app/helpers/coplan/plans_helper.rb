module CoPlan
  module PlansHelper
    include MarkdownHelper

    # Short preview of the plan's content for cards on the index page.
    # Once an AI summary column lands (COPLAN-24), the card view prefers
    # `plan.summary` and falls back to this helper.
    STATUS_HINTS = {
      "brainstorm" => "Private draft — only you can see it",
      "considering" => "Published — open for review and feedback",
      "developing" => "Being implemented",
      "live" => "Shipped and in production",
      "abandoned" => "No longer pursued"
    }.freeze

    def plan_status_hint(status)
      STATUS_HINTS[status]
    end

    # Moving a brainstorm to any public status publishes it org-wide —
    # worth a confirmation click.
    def status_publishes?(plan, new_status)
      plan.status == "brainstorm" && new_status != "brainstorm"
    end

    def plan_content_preview(plan, limit: 200)
      content = plan.current_content
      return nil if content.blank?

      plain = markdown_to_plain_text(content)
      return nil if plain.blank?

      truncate(plain, length: limit, omission: "…", separator: " ")
    end
  end
end
