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
      # One preview builder for OG tags, Slack unfurls, and anything else —
      # its context carries the Private/Archived flag (published unmarked).
      preview = LinkPreviews.for_plan(plan, base_url: request.base_url + coplan.root_path)
      truncate([ preview.context, preview.description ].compact.join(" — "), length: 250, omission: "…")
    end

    # Canonical URL for a user's profile — username when they have one
    # (readable, stable), id otherwise.
    def profile_path_for(user)
      profile_path(user.username.presence || user.id)
    end

    # Author names everywhere in the app link to profiles.
    def profile_link(user, css_class: "profile-link")
      return "" unless user
      link_to user.name, profile_path_for(user), class: css_class
    end

    def user_avatar(user, size: "sm")
      initials = user.name.split.map { |w| w[0] }.first(2).join.upcase
      if user.avatar_url.present?
        tag.img(src: user.avatar_url, alt: user.name, class: "avatar avatar--#{size}", loading: "lazy")
      else
        tag.span(initials, class: "avatar avatar--#{size} avatar--initials", title: user.name)
      end
    end

    # Non-production environments mark the nav logo instead of adding a
    # badge next to the brand — a badge changes the nav's layout, so dev
    # and staging would never reproduce production's spacing. The logo
    # gets a colored ring (same palette as the favicon) and a tooltip.
    def coplan_environment_logo_modifier
      return "" if Rails.env.production?

      " site-nav__logo--#{Rails.env}"
    end

    def coplan_environment_logo_title
      return if Rails.env.production?

      "#{Rails.env.capitalize} environment"
    end
  end
end
