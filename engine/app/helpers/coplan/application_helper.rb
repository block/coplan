module CoPlan
  module ApplicationHelper
    include MarkdownHelper
    FAVICON_COLORS = {
      "production"  => { start: "#3B82F6", stop: "#1E40AF" },
      "staging"     => { start: "#F59E0B", stop: "#D97706" },
      "development" => { start: "#10B981", stop: "#047857" },
    }.freeze

    def coplan_favicon_tag
      colors = FAVICON_COLORS.fetch(Rails.env, FAVICON_COLORS["development"])
      svg = <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <defs>
            <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stop-color="#{colors[:start]}"/>
              <stop offset="100%" stop-color="#{colors[:stop]}"/>
            </linearGradient>
          </defs>
          <rect width="100" height="100" rx="22" fill="url(#g)"/>
          <g opacity=".25" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round">
            <line x1="16" y1="18" x2="84" y2="18"/>
            <line x1="16" y1="28" x2="84" y2="28"/>
            <line x1="16" y1="38" x2="84" y2="38"/>
            <line x1="16" y1="48" x2="84" y2="48"/>
            <line x1="16" y1="58" x2="84" y2="58"/>
            <line x1="16" y1="68" x2="84" y2="68"/>
            <line x1="16" y1="78" x2="84" y2="78"/>
          </g>
          <circle cx="40" cy="46" r="22" fill="#fff" opacity=".55"/>
          <path d="M26,62 L18,78 L36,66 Z" fill="#fff" opacity=".55"/>
          <circle cx="62" cy="54" r="22" fill="#fff" opacity=".55"/>
          <path d="M76,70 L84,84 L68,72 Z" fill="#fff" opacity=".55"/>
        </svg>
      SVG

      data_uri = "data:image/svg+xml,#{ERB::Util.url_encode(svg.strip)}"
      tag.link(rel: "icon", type: "image/svg+xml", href: data_uri)
    end

    def plan_og_description(plan)
      status = plan.status.capitalize
      author = plan.created_by_user.name
      prefix = "#{status} · by #{author}"
      content = plan.current_content
      return prefix if content.blank?

      plain = markdown_to_plain_text(content)
      truncated = truncate(plain, length: 200, omission: "…")
      "#{prefix} — #{truncated}"
    end

    def coplan_environment_badge
      return if Rails.env.production?

      label = Rails.env.capitalize
      colors = FAVICON_COLORS.fetch(Rails.env, FAVICON_COLORS["development"])
      tag.span(label, class: "env-badge", style: "background: #{colors[:start]};")
    end
  end
end
