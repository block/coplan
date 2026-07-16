module CoPlan
  module PlansHelper
    include MarkdownHelper

    # Short preview of the plan's content for cards on the index page.
    # Once an AI summary column lands (COPLAN-24), the card view prefers
    # `plan.summary` and falls back to this helper.
    def plan_content_preview(plan, limit: 200)
      content = plan.current_content
      return nil if content.blank?

      # Cached per content SHA: without this, every index page fell back to a
      # full Commonmarker + Nokogiri parse per plan without an AI summary.
      cache_key = ["coplan/plan-preview", MarkdownHelper::RENDER_CACHE_VERSION, plan.id,
                   plan.current_plan_version&.content_sha256 || plan.current_revision]
      plain = Rails.cache.fetch(cache_key) { markdown_to_plain_text(content) }
      return nil if plain.blank?

      truncate(plain, length: limit, omission: "…", separator: " ")
    end
  end
end
