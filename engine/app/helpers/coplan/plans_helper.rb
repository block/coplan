module CoPlan
  module PlansHelper
    include MarkdownHelper

    # State badge for a plan: drafts and archived plans announce themselves;
    # published-and-active is the normal state and renders nothing. Safe in
    # broadcast partials (derives from the plan alone, no current_user).
    def plan_state_badge(plan)
      badges = []
      badges << content_tag(:span, "Draft", class: "badge badge--draft", title: "Private draft — only the author can see it") if plan.draft?
      badges << content_tag(:span, "Archived", class: "badge badge--archived", title: "Hidden from lists unless filtered for") if plan.archived?
      return "".html_safe if badges.empty?

      safe_join([" · ", safe_join(badges, " ")])
    end

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
