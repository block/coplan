module CoPlan
  module ApplicationHelper
    include CoPlan::KeyboardShortcutsHelper
    include MarkdownHelper

    # The app theme for this page, as <html data-app-theme> (docs/THEMES.md).
    def coplan_app_theme
      CoPlan::Themes.default.key
    end

    def coplan_favicon_tag
      safe_join([
        tag.link(rel: "icon", type: "image/png", sizes: "192x192", href: asset_path(coplan_logo_asset(format: :png))),
        tag.link(rel: "icon", type: "image/svg+xml", sizes: "any", href: asset_path(coplan_logo_asset))
      ])
    end

    def plan_og_description(plan)
      # One preview builder for OG tags, Slack unfurls, and anything else —
      # its context carries the Private/Archived flag (published unmarked).
      preview = LinkPreviews.for_plan(plan, base_url: request.base_url + coplan.root_path)
      truncate([ preview.context, preview.description ].compact.join(" — "), length: 250, omission: "…")
    end

    # Where a person lives: their library, which is their page. Their handle
    # is usually their username, but not always (collisions get a suffix),
    # so it has to be read rather than derived.
    #
    # Memoized per request because list pages ask for the same few authors
    # over and over — one lookup per distinct person, not per row. A library
    # is materialized on first touch (User#library), so the first ask for
    # someone who has never had one also creates it.
    def profile_path_for(user)
      handles = (@browse_handles ||= {})
      browse_library_path(handle: handles[user.id] ||= user.library.handle)
    end

    # Author names everywhere in the app link to their library.
    def profile_link(user, css_class: "profile-link")
      return "" unless user
      link_to user.name, profile_path_for(user), class: css_class
    end

    def user_avatar(user, size: "sm", css_class: "avatar avatar--#{size} avatar--initials")
      initials = user.name.split.map { |w| w[0] }.first(2).join.upcase
      tag.span(class: css_class, role: "img", aria: { label: user.name }, title: user.name) do
        photo = if user.avatar_url.present?
          tag.img(src: user.avatar_url, alt: "", class: "avatar__image", loading: "lazy",
            data: { controller: "coplan--avatar", action: "load->coplan--avatar#loaded error->coplan--avatar#failed" })
        end
        safe_join([ initials, photo ])
      end
    end

    # The nav, favicon, and notification icon share one environment palette.
    def coplan_logo_asset(format: :svg)
      suffix = case Rails.env
      when "development" then "-development"
      when "staging" then "-staging"
      else ""
      end

      "coplan/coplan-logo#{suffix}.#{format}"
    end

    def coplan_environment_logo_title
      return if Rails.env.production?

      "#{Rails.env.capitalize} environment"
    end
  end
end
