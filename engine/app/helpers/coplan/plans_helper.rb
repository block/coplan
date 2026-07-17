module CoPlan
  module PlansHelper
    include MarkdownHelper

    # Published is the unmarked normal state. The hidden states (draft,
    # archived) get a quiet crossed-out eye — "this one isn't listed" —
    # rather than a loud colored badge. Safe in broadcast partials
    # (derives from the plan alone, no current_user).
    HIDDEN_EYE_ICON = <<~SVG.html_safe.freeze
      <svg class="state-flag__eye" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/><path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/><path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/><line x1="2" x2="22" y1="2" y2="22"/></svg>
    SVG

    def plan_state_badge(plan)
      flags = []
      flags << hidden_state_flag("Draft", "Unlisted draft — anyone with the link can read it, but it stays out of lists and search") if plan.draft?
      flags << hidden_state_flag("Archived", "Hidden from lists unless filtered for") if plan.archived?
      return "".html_safe if flags.empty?

      safe_join([" ", safe_join(flags, " ")])
    end

    def hidden_state_flag(label, title)
      content_tag(:span, safe_join([HIDDEN_EYE_ICON, label]), class: "state-flag", title: title)
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
